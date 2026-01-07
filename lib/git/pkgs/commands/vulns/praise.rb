# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        class Praise
          include Base

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs vulns praise [options]"
            opts.separator ""
            opts.separator "Show who fixed vulnerabilities (opposite of blame)."
            opts.separator ""
            opts.separator "Options:"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-s", "--severity=LEVEL", "Minimum severity (critical, high, medium, low)") do |v|
              options[:severity] = v
            end

            opts.on("-b", "--branch=NAME", "Branch to analyze") do |v|
              options[:branch] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
            end

            opts.on("--summary", "Show author leaderboard") do
              options[:summary] = true
            end

            opts.on("-h", "--help", "Show this help") do
              puts opts
              exit
            end
          end

          parser.parse!(@args)
          options
        end

        def run
          repo = Repository.new

          unless Database.exists?(repo.git_dir)
            error "No database found. Run 'git pkgs init' first. Praise requires commit history."
          end

          Database.connect(repo.git_dir)

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

          praise_results = []

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

              fix_info = find_fixing_commit_info(pkg.ecosystem, pkg.name, vp)
              next unless fix_info

              severity = vp.vulnerability&.severity

              if @options[:severity]
                min_level = SEVERITY_ORDER[@options[:severity].downcase] || 4
                next unless (SEVERITY_ORDER[severity&.downcase] || 4) <= min_level
              end

              praise_results << {
                id: vp.vulnerability_id,
                severity: severity,
                package_name: pkg.name,
                from_version: fix_info[:from_version],
                to_version: fix_info[:to_version],
                summary: vp.vulnerability&.summary,
                fixing_commit: fix_info[:commit_info],
                days_exposed: fix_info[:days_exposed],
                days_after_disclosure: fix_info[:days_after_disclosure]
              }
            end
          end

          if praise_results.empty?
            puts "No fixed vulnerabilities found"
            return
          end

          praise_results.sort_by! do |v|
            [SEVERITY_ORDER[v[:severity]&.downcase] || 4, v[:package_name]]
          end

          if @options[:format] == "json"
            require "json"
            if @options[:summary]
              puts JSON.pretty_generate(compute_author_summary(praise_results))
            else
              puts JSON.pretty_generate(praise_results)
            end
          elsif @options[:summary]
            output_author_summary(praise_results)
          else
            output_praise_text(praise_results)
          end
        end

        def compute_author_summary(results)
          by_author = results.group_by { |r| r[:fixing_commit][:author] }

          summaries = by_author.map do |author, fixes|
            times = fixes.map { |f| f[:days_after_disclosure] }.compact
            avg_time = times.empty? ? nil : (times.sum.to_f / times.size).round(1)

            by_sev = {}
            %w[critical high medium low].each do |sev|
              count = fixes.count { |f| f[:severity]&.downcase == sev }
              by_sev[sev] = count if count > 0
            end

            {
              author: author,
              total_fixes: fixes.size,
              avg_days_to_fix: avg_time,
              by_severity: by_sev
            }
          end

          summaries.sort_by { |s| -s[:total_fixes] }
        end

        def output_author_summary(results)
          summaries = compute_author_summary(results)

          max_author = summaries.map { |s| s[:author].length }.max || 20
          max_fixes = summaries.map { |s| s[:total_fixes].to_s.length }.max || 3

          puts "Author".ljust(max_author) + "  Fixes  Avg Days  Critical  High  Medium  Low"
          puts "-" * (max_author + 50)

          summaries.each do |s|
            author = s[:author].ljust(max_author)
            fixes = s[:total_fixes].to_s.rjust(max_fixes)
            avg = s[:avg_days_to_fix] ? "#{s[:avg_days_to_fix]}d".rjust(8) : "N/A".rjust(8)
            crit = (s[:by_severity]["critical"] || 0).to_s.rjust(8)
            high = (s[:by_severity]["high"] || 0).to_s.rjust(4)
            med = (s[:by_severity]["medium"] || 0).to_s.rjust(6)
            low = (s[:by_severity]["low"] || 0).to_s.rjust(4)

            puts "#{author}  #{fixes}  #{avg}  #{crit}  #{high}  #{med}  #{low}"
          end
        end

        def find_fixing_commit_info(ecosystem, package_name, vuln_pkg)
          changes = Models::DependencyChange
            .join(:commits, id: :commit_id)
            .where(ecosystem: ecosystem, name: package_name)
            .where(change_type: %w[added modified])
            .order(Sequel[:commits][:committed_at])
            .eager(:commit)
            .all

          introducing_change = changes.find { |c| vuln_pkg.affects_version?(c.requirement) }
          return nil unless introducing_change

          introduced_at = introducing_change.commit.committed_at

          # Find when it was fixed
          fix_changes = Models::DependencyChange
            .join(:commits, id: :commit_id)
            .where(ecosystem: ecosystem, name: package_name)
            .where(change_type: %w[modified removed])
            .where { Sequel[:commits][:committed_at] > introduced_at }
            .order(Sequel[:commits][:committed_at])
            .eager(:commit)
            .all

          fixing_change = fix_changes.find do |c|
            c.change_type == "removed" || !vuln_pkg.affects_version?(c.requirement)
          end

          return nil unless fixing_change

          fixed_at = fixing_change.commit.committed_at
          published_at = vuln_pkg.vulnerability&.published_at

          days_exposed = ((fixed_at - introduced_at) / 86400).round
          days_after_disclosure = if published_at && fixed_at > published_at
                                    ((fixed_at - published_at) / 86400).round
                                  end

          {
            commit_info: format_commit_info(fixing_change.commit),
            from_version: introducing_change.requirement,
            to_version: fixing_change.change_type == "removed" ? "(removed)" : fixing_change.requirement,
            days_exposed: days_exposed,
            days_after_disclosure: days_after_disclosure
          }
        end

        def output_praise_text(results)
          max_severity = results.map { |v| (v[:severity] || "").length }.max || 8
          max_id = results.map { |v| v[:id].length }.max || 15
          max_pkg = results.map { |v| v[:package_name].length }.max || 20

          results.each do |result|
            severity = (result[:severity] || "unknown").upcase.ljust(max_severity)
            id = result[:id].ljust(max_id)
            pkg = result[:package_name].ljust(max_pkg)

            fix = result[:fixing_commit]
            commit_info = "#{fix[:sha]}  #{fix[:date]}  #{fix[:author]}  \"#{fix[:message]}\""

            days_info = if result[:days_after_disclosure]
                          "(#{result[:days_after_disclosure]}d after disclosure)"
                        else
                          "(#{result[:days_exposed]}d total)"
                        end

            line = "#{severity}  #{id}  #{pkg}  #{commit_info}  #{days_info}"
            colored_line = case result[:severity]&.downcase
                           when "critical", "high" then Color.green(line)
                           when "medium" then Color.green(line)
                           when "low" then Color.green(line)
                           else Color.green(line)
                           end
            puts colored_line
          end
        end
        end
      end
    end
  end
end
