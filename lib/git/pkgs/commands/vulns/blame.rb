# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        class Blame
          include Base

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs vulns blame [ref] [options]"
            opts.separator ""
            opts.separator "Show who introduced each vulnerability."
            opts.separator ""
            opts.separator "Arguments:"
            opts.separator "  ref                    Git ref to analyze (default: HEAD)"
            opts.separator ""
            opts.separator "Options:"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-s", "--severity=LEVEL", "Minimum severity (critical, high, medium, low)") do |v|
              options[:severity] = v
            end

            opts.on("-r", "--ref=REF", "Git ref to analyze (default: HEAD)") do |v|
              options[:ref] = v
            end

            opts.on("-b", "--branch=NAME", "Branch context for finding commits") do |v|
              options[:branch] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
            end

            opts.on("--all-time", "Show blame for all historical vulnerabilities") do
              options[:all_time] = true
            end

            opts.on("-h", "--help", "Show this help") do
              puts opts
              exit
            end
          end

          parser.parse!(@args)
          options[:ref] ||= @args.shift unless @args.empty?
          options
        end

        def run
          repo = Repository.new

          unless Database.exists?(repo.git_dir)
            error "No database found. Run 'git pkgs init' first. Blame requires commit history."
          end

          Database.connect(repo.git_dir)

          if @options[:all_time]
            run_all_time(repo)
          else
            run_at_ref(repo)
          end
        end

        def run_at_ref(repo)
          ref = @options[:ref] || "HEAD"
          commit_sha = repo.rev_parse(ref)
          target_commit = Models::Commit.first(sha: commit_sha)

          unless target_commit
            error "Commit #{commit_sha[0, 7]} not in database. Run 'git pkgs update' first."
          end

          deps = compute_dependencies_at_commit(target_commit, repo)

          if deps.empty?
            empty_result "No dependencies found"
            return
          end

          supported_deps = deps.select { |d| Ecosystems.supported?(d[:ecosystem]) }
          vulns = scan_for_vulnerabilities(supported_deps)

          if @options[:severity]
            min_level = SEVERITY_ORDER[@options[:severity].downcase] || 4
            vulns = vulns.select { |v| (SEVERITY_ORDER[v[:severity]&.downcase] || 4) <= min_level }
          end

          if vulns.empty?
            puts "No known vulnerabilities found"
            return
          end

          blame_results = vulns.map do |vuln|
            introducing = find_introducing_commit(
              vuln[:ecosystem],
              vuln[:package_name],
              vuln[:id],
              target_commit
            )

            vuln.merge(introducing_commit: introducing)
          end

          output_results(blame_results)
        end

        def run_all_time(repo)
          branch_name = @options[:branch] || repo.default_branch
          branch = Models::Branch.first(name: branch_name)

          unless branch&.last_analyzed_sha
            error "No analysis found for branch '#{branch_name}'. Run 'git pkgs init' first."
          end

          # Get all unique packages from dependency changes
          packages = Models::DependencyChange
            .select(:ecosystem, :name)
            .select_group(:ecosystem, :name)
            .all

          blame_results = []

          packages.each do |pkg|
            next unless Ecosystems.supported?(pkg.ecosystem)

            osv_ecosystem = Ecosystems.to_osv(pkg.ecosystem)
            next unless osv_ecosystem

            vuln_pkgs = Models::VulnerabilityPackage
              .for_package(osv_ecosystem, pkg.name)
              .eager(:vulnerability)
              .all

            vuln_pkgs.each do |vp|
              next if vp.vulnerability&.withdrawn?

              introducing = find_historical_introducing_commit(pkg.ecosystem, pkg.name, vp)
              next unless introducing

              severity = vp.vulnerability&.severity

              if @options[:severity]
                min_level = SEVERITY_ORDER[@options[:severity].downcase] || 4
                next unless (SEVERITY_ORDER[severity&.downcase] || 4) <= min_level
              end

              blame_results << {
                id: vp.vulnerability_id,
                severity: severity,
                package_name: pkg.name,
                package_version: introducing[:version],
                summary: vp.vulnerability&.summary,
                introducing_commit: introducing[:commit_info],
                status: introducing[:status]
              }
            end
          end

          if blame_results.empty?
            puts "No historical vulnerabilities found"
            return
          end

          output_results(blame_results)
        end

        def find_historical_introducing_commit(ecosystem, package_name, vuln_pkg)
          window = find_vulnerability_window(ecosystem, package_name, vuln_pkg)
          return nil unless window

          {
            commit_info: format_commit_info(window[:introducing].commit),
            version: window[:introducing].requirement,
            status: window[:status]
          }
        end

        def output_results(blame_results)
          blame_results.sort_by! do |v|
            [SEVERITY_ORDER[v[:severity]&.downcase] || 4, v[:package_name]]
          end

          if @options[:format] == "json"
            require "json"
            puts JSON.pretty_generate(blame_results)
          else
            output_blame_text(blame_results)
          end
        end

        def find_introducing_commit(ecosystem, package_name, vuln_id, up_to_commit)
          osv_ecosystem = Ecosystems.to_osv(ecosystem)
          vuln_pkg = Models::VulnerabilityPackage.first(
            vulnerability_id: vuln_id,
            ecosystem: osv_ecosystem,
            package_name: package_name
          )

          return nil unless vuln_pkg

          changes = Models::DependencyChange
            .join(:commits, id: :commit_id)
            .where(ecosystem: ecosystem, name: package_name)
            .where(change_type: %w[added modified])
            .where { Sequel[:commits][:committed_at] <= up_to_commit.committed_at }
            .order(Sequel.desc(Sequel[:commits][:committed_at]))
            .eager(:commit)
            .all

          changes.each do |change|
            next unless vuln_pkg.affects_version?(change.requirement)
            return format_commit_info(change.commit)
          end

          first_add = Models::DependencyChange
            .join(:commits, id: :commit_id)
            .where(ecosystem: ecosystem, name: package_name)
            .where(change_type: "added")
            .order(Sequel[:commits][:committed_at])
            .eager(:commit)
            .first

          return format_commit_info(first_add.commit) if first_add && vuln_pkg.affects_version?(first_add.requirement)

          nil
        end

        def output_blame_text(results)
          has_status = results.any? { |r| r[:status] }
          max_severity = results.map { |v| (v[:severity] || "").length }.max || 8
          max_id = results.map { |v| v[:id].length }.max || 15
          max_pkg = results.map { |v| "#{v[:package_name]} #{v[:package_version]}".length }.max || 20

          results.each do |result|
            severity = (result[:severity] || "unknown").upcase.ljust(max_severity)
            id = result[:id].ljust(max_id)
            pkg = "#{result[:package_name]} #{result[:package_version]}".ljust(max_pkg)

            intro = result[:introducing_commit]
            commit_info = if intro
                            "#{intro[:sha]}  #{intro[:date]}  #{intro[:author]}  \"#{intro[:message]}\""
                          else
                            "(unknown origin)"
                          end

            status_str = has_status ? "  [#{result[:status]}]" : ""
            line = "#{severity}  #{id}  #{pkg}  #{commit_info}#{status_str}"
            colored_line = case result[:severity]&.downcase
                           when "critical", "high" then Color.red(line)
                           when "medium" then Color.yellow(line)
                           when "low" then Color.cyan(line)
                           else line
                           end
            puts colored_line
          end
        end
        end
      end
    end
  end
end
