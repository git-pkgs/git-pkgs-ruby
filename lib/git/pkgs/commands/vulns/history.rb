# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        class History
          include Base

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs vulns history <package|cve> [options]"
            opts.separator ""
            opts.separator "Show vulnerability timeline for a specific package or CVE."
            opts.separator ""
            opts.separator "Arguments:"
            opts.separator "  package|cve            Package name or CVE/GHSA ID"
            opts.separator ""
            opts.separator "Examples:"
            opts.separator "  git pkgs vulns history lodash"
            opts.separator "  git pkgs vulns history CVE-2024-1234"
            opts.separator "  git pkgs vulns history GHSA-xxxx-yyyy"
            opts.separator ""
            opts.separator "Options:"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("--since=DATE", "Show events after date") do |v|
              options[:since] = v
            end

            opts.on("--until=DATE", "Show events before date") do |v|
              options[:until] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
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

          unless Database.exists?(repo.git_dir)
            error "No database found. Run 'git pkgs init' first. History requires commit history."
          end

          Database.connect(repo.git_dir)

          target = @options[:target]
          error "Usage: git pkgs vulns history <package|cve>" unless target

          if target.match?(/^(CVE-|GHSA-)/i)
            run_cve_history(target.upcase, repo)
          else
            run_package_history(target, repo)
          end
        end

        def run_cve_history(cve_id, repo)
          ensure_vulns_synced

          vuln = Models::Vulnerability.first(id: cve_id)
          unless vuln
            error "Vulnerability #{cve_id} not found. Run 'git pkgs vulns sync' first."
          end

          vuln_pkgs = Models::VulnerabilityPackage.where(vulnerability_id: cve_id).all

          if vuln_pkgs.empty?
            puts "No affected packages found for #{cve_id}"
            return
          end

          timeline = []

          if vuln.published_at
            timeline << {
              date: vuln.published_at,
              event_type: :cve_published,
              description: "#{cve_id} published",
              severity: vuln.severity
            }
          end

          vuln_pkgs.each do |vp|
            ecosystem = Ecosystems.from_osv(vp.ecosystem) || vp.ecosystem.downcase
            changes = Models::DependencyChange
              .join(:commits, id: :commit_id)
              .where(ecosystem: ecosystem, name: vp.package_name)
              .order(Sequel[:commits][:committed_at])
              .eager(:commit)
              .all

            changes.each do |change|
              current_affected = change.requirement && vp.affects_version?(change.requirement)
              previous_affected = change.previous_requirement && vp.affects_version?(change.previous_requirement)

              event = nil
              case change.change_type
              when "added"
                if current_affected
                  event = {
                    date: change.commit.committed_at,
                    event_type: :vulnerable_added,
                    description: "#{vp.package_name} #{change.requirement} added (vulnerable)",
                    commit: format_commit_info(change.commit)
                  }
                end
              when "modified"
                if current_affected && !previous_affected
                  event = {
                    date: change.commit.committed_at,
                    event_type: :became_vulnerable,
                    description: "#{vp.package_name} updated to #{change.requirement} (vulnerable)",
                    commit: format_commit_info(change.commit)
                  }
                elsif !current_affected && previous_affected
                  event = {
                    date: change.commit.committed_at,
                    event_type: :fixed,
                    description: "#{vp.package_name} updated to #{change.requirement} (fixed)",
                    commit: format_commit_info(change.commit)
                  }
                end
              when "removed"
                if previous_affected
                  event = {
                    date: change.commit.committed_at,
                    event_type: :removed,
                    description: "#{vp.package_name} removed",
                    commit: format_commit_info(change.commit)
                  }
                end
              end

              timeline << event if event
            end
          end

          timeline = filter_timeline_by_date(timeline)
          timeline.sort_by! { |e| e[:date] }

          if timeline.empty?
            puts "No history found for #{cve_id}"
            return
          end

          if @options[:format] == "json"
            require "json"
            puts JSON.pretty_generate({
              cve: cve_id,
              severity: vuln.severity,
              summary: vuln.summary,
              published_at: vuln.published_at&.strftime("%Y-%m-%d"),
              timeline: timeline.map { |e| e.merge(date: e[:date].strftime("%Y-%m-%d")) }
            })
          else
            output_cve_timeline(cve_id, vuln, timeline)
          end
        end

        def run_package_history(package_name, repo)
          ensure_vulns_synced

          ecosystem = @options[:ecosystem]

          changes_query = Models::DependencyChange
            .join(:commits, id: :commit_id)
            .where(Sequel.ilike(:name, package_name))
            .order(Sequel[:commits][:committed_at])
            .eager(:commit, :manifest)

          changes_query = changes_query.where(ecosystem: ecosystem) if ecosystem

          changes = changes_query.all

          if changes.empty?
            puts "No history found for package '#{package_name}'"
            return
          end

          osv_ecosystem = ecosystem ? Ecosystems.to_osv(ecosystem) : nil
          vuln_query = Models::VulnerabilityPackage.where(Sequel.ilike(:package_name, package_name))
          vuln_query = vuln_query.where(ecosystem: osv_ecosystem) if osv_ecosystem

          vuln_pkgs = vuln_query.eager(:vulnerability).all

          timeline = []

          changes.each do |change|
            affected_vulns = vuln_pkgs.select do |vp|
              next false if vp.vulnerability&.withdrawn?
              change.requirement && vp.affects_version?(change.requirement)
            end

            vuln_info = if affected_vulns.any?
                          "(vulnerable to #{affected_vulns.map { |vp| vp.vulnerability_id }.join(", ")})"
                        else
                          ""
                        end

            event = {
              date: change.commit.committed_at,
              event_type: change.change_type.to_sym,
              description: "#{change.change_type.capitalize} #{package_name} #{change.requirement} #{vuln_info}".strip,
              version: change.requirement,
              commit: format_commit_info(change.commit),
              affected_vulns: affected_vulns.map(&:vulnerability_id)
            }

            timeline << event
          end

          vuln_pkgs.each do |vp|
            next unless vp.vulnerability&.published_at
            next if vp.vulnerability.withdrawn?

            timeline << {
              date: vp.vulnerability.published_at,
              event_type: :cve_published,
              description: "#{vp.vulnerability_id} published (#{vp.vulnerability.severity || "unknown"} severity)"
            }
          end

          timeline = filter_timeline_by_date(timeline)
          timeline.sort_by! { |e| e[:date] }

          if timeline.empty?
            puts "No history found for package '#{package_name}'"
            return
          end

          if @options[:format] == "json"
            require "json"
            puts JSON.pretty_generate({
              package: package_name,
              timeline: timeline.map { |e| e.merge(date: e[:date].strftime("%Y-%m-%d")) }
            })
          else
            output_package_timeline(package_name, timeline)
          end
        end

        def filter_timeline_by_date(timeline)
          if @options[:since]
            since_time = parse_date(@options[:since])
            timeline = timeline.select { |e| e[:date] >= since_time }
          end

          if @options[:until]
            until_time = parse_date(@options[:until])
            timeline = timeline.select { |e| e[:date] <= until_time }
          end

          timeline
        end

        def output_cve_timeline(cve_id, vuln, timeline)
          puts "#{cve_id} (#{vuln.severity || "unknown"} severity)"
          puts vuln.summary if vuln.summary
          puts ""

          timeline.each do |event|
            date = event[:date].strftime("%Y-%m-%d")
            desc = event[:description]

            line = if event[:commit]
                     "#{date}  #{desc}  #{event[:commit][:sha]}  #{event[:commit][:author]}"
                   else
                     "#{date}  #{desc}"
                   end

            colored_line = case event[:event_type]
                           when :cve_published then Color.yellow(line)
                           when :vulnerable_added, :became_vulnerable then Color.red(line)
                           when :fixed, :removed then Color.green(line)
                           else line
                           end
            puts colored_line
          end
        end

        def output_package_timeline(package_name, timeline)
          puts "History for #{package_name}"
          puts ""

          timeline.each do |event|
            date = event[:date].strftime("%Y-%m-%d")
            desc = event[:description]

            line = if event[:commit]
                     "#{date}  #{desc}  #{event[:commit][:sha]}  #{event[:commit][:author]}"
                   else
                     "#{date}  #{desc}"
                   end

            colored_line = case event[:event_type]
                           when :cve_published then Color.yellow(line)
                           when :added
                             event[:affected_vulns]&.any? ? Color.red(line) : line
                           when :modified
                             event[:affected_vulns]&.any? ? Color.red(line) : Color.green(line)
                           when :removed then Color.cyan(line)
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
