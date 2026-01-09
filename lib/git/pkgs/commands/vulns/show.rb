# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        class Show
          include Base

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs vulns show <cve> [options]"
            opts.separator ""
            opts.separator "Show details about a specific CVE."
            opts.separator ""
            opts.separator "Arguments:"
            opts.separator "  cve                    CVE or GHSA ID (e.g., CVE-2024-1234)"
            opts.separator ""
            opts.separator "Options:"

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
            end

            opts.on("-r", "--ref=REF", "Git ref for exposure analysis (default: HEAD)") do |v|
              options[:ref] = v
            end

            opts.on("-b", "--branch=NAME", "Branch context for finding snapshots") do |v|
              options[:branch] = v
            end

            opts.on("-h", "--help", "Show this help") do
              puts opts
              exit
            end
          end

          parser.parse!(@args)
          options[:target] = @args.shift
          options
        end

        def run
          repo = Repository.new

          cve_id = @options[:target]
          error "Usage: git pkgs vulns show <cve>" unless cve_id
          cve_id = cve_id.upcase

          has_db = Database.exists?(repo.git_dir)
          Database.connect(repo.git_dir) if has_db

          ensure_vulns_synced if has_db

          vuln = Models::Vulnerability.first(id: cve_id)
          unless vuln
            error "Vulnerability #{cve_id} not found. Try 'git pkgs vulns sync' first."
          end

          vuln_pkgs = Models::VulnerabilityPackage.where(vulnerability_id: cve_id).eager(:vulnerability).all

          if @options[:format] == "json"
            require "json"
            output = build_show_json(vuln, vuln_pkgs, repo, has_db)
            puts JSON.pretty_generate(output)
          else
            output_show_text(vuln, vuln_pkgs, repo, has_db)
          end
        end

        def build_show_json(vuln, vuln_pkgs, repo, has_db)
          output = {
            id: vuln.id,
            severity: vuln.severity,
            summary: vuln.summary,
            details: vuln.details,
            published_at: vuln.published_at&.strftime("%Y-%m-%d"),
            affected_packages: vuln_pkgs.map do |vp|
              {
                ecosystem: vp.ecosystem,
                package: vp.package_name,
                affected_versions: vp.affected_versions,
                fixed_versions: vp.fixed_versions
              }
            end
          }

          if has_db
            output[:your_exposure] = find_exposure_for_vuln(vuln, vuln_pkgs, repo)
          end

          output
        end

        def output_show_text(vuln, vuln_pkgs, repo, has_db)
          header = "#{vuln.id} (#{vuln.severity || "unknown"} severity)"
          colored_header = case vuln.severity&.downcase
                           when "critical", "high" then Color.red(header)
                           when "medium" then Color.yellow(header)
                           when "low" then Color.cyan(header)
                           else header
                           end
          puts colored_header
          puts vuln.summary if vuln.summary
          puts ""

          puts "Affected packages:"
          vuln_pkgs.each do |vp|
            fixed_info = vp.fixed_versions.to_s.empty? ? "" : " (fixed in #{vp.fixed_versions})"
            puts "  #{vp.ecosystem}/#{vp.package_name}: #{vp.affected_versions}#{fixed_info}"
          end

          puts ""
          puts "Published: #{vuln.published_at&.strftime("%Y-%m-%d") || "unknown"}"

          if vuln.references && !vuln.references.empty?
            puts ""
            puts "References:"
            refs = begin
              JSON.parse(vuln.references)
            rescue JSON::ParserError
              []
            end
            refs.each do |ref|
              puts "  #{ref["url"]}" if ref["url"]
            end
          end

          return unless has_db

          exposures = find_exposure_for_vuln(vuln, vuln_pkgs, repo)
          return if exposures.empty?

          puts ""
          puts "Your exposure:"
          exposures.each do |exposure|
            pkg_line = "  #{exposure[:package]} #{exposure[:version]} in #{exposure[:manifest_path]}"
            puts Color.send(:red, pkg_line)

            if exposure[:introduced_by]
              intro = exposure[:introduced_by]
              puts "    Added: #{intro[:sha]} #{intro[:date]} #{intro[:author]} \"#{intro[:message]}\""
            end

            if exposure[:fixed_by]
              fix = exposure[:fixed_by]
              puts Color.send(:green, "    Fixed: #{fix[:sha]} #{fix[:date]} #{fix[:author]} \"#{fix[:message]}\"")
            elsif exposure[:status] == "ongoing"
              puts Color.send(:yellow, "    Status: Still vulnerable")
            end
          end
        end

        def find_exposure_for_vuln(vuln, vuln_pkgs, repo)
          exposures = []
          ref = @options[:ref] || "HEAD"

          begin
            commit_sha = repo.rev_parse(ref)
            target_commit = Models::Commit.first(sha: commit_sha)
          rescue Rugged::ReferenceError
            return exposures
          end

          return exposures unless target_commit

          deps = compute_dependencies_at_commit(target_commit, repo)

          vuln_pkgs.each do |vp|
            ecosystem = Ecosystems.from_osv(vp.ecosystem) || vp.ecosystem.downcase

            matching_deps = deps.select do |dep|
              dep[:ecosystem] == ecosystem &&
                dep[:name].downcase == vp.package_name.downcase &&
                vp.affects_version?(dep[:requirement])
            end

            matching_deps.each do |dep|
              exposure = {
                package: dep[:name],
                version: dep[:requirement],
                ecosystem: dep[:ecosystem],
                manifest_path: dep[:manifest_path]
              }

              intro_change = find_introducing_change(dep[:ecosystem], dep[:name], vp, target_commit)
              exposure[:introduced_by] = format_commit_info(intro_change&.commit) if intro_change

              fix_change = find_fixing_change(dep[:ecosystem], dep[:name], vp, target_commit, intro_change&.commit&.committed_at)
              if fix_change
                exposure[:fixed_by] = format_commit_info(fix_change.commit)
                exposure[:status] = "fixed"
              else
                exposure[:status] = "ongoing"
              end

              exposures << exposure
            end
          end

          exposures
        end
        end
      end
    end
  end
end
