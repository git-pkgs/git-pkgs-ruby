# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        class Exposure
          include Base

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs vulns exposure [ref] [options]"
            opts.separator ""
            opts.separator "Calculate exposure windows and remediation metrics."
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

            opts.on("--summary", "Show aggregate metrics only") do
              options[:summary] = true
            end

            opts.on("--all-time", "Show stats for all historical vulnerabilities") do
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
            error "No database found. Run 'git pkgs init' first. Exposure analysis requires commit history."
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

          exposure_data = vulns.map do |vuln|
            calculate_exposure(vuln, target_commit)
          end.compact

          output_results(exposure_data)
        end

        def run_all_time(repo)
          branch_name = @options[:branch] || repo.default_branch
          branch = Models::Branch.first(name: branch_name)

          unless branch&.last_analyzed_sha
            error "No analysis found for branch '#{branch_name}'. Run 'git pkgs init' first."
          end

          last_commit = Models::Commit.first(sha: branch.last_analyzed_sha)

          # Get all unique packages from dependency changes
          packages = Models::DependencyChange
            .select(:ecosystem, :name)
            .select_group(:ecosystem, :name)
            .all

          exposure_data = []

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

              exposure = calculate_historical_exposure(pkg.ecosystem, pkg.name, vp, last_commit)
              next unless exposure

              if @options[:severity]
                min_level = SEVERITY_ORDER[@options[:severity].downcase] || 4
                next unless (SEVERITY_ORDER[exposure[:severity]&.downcase] || 4) <= min_level
              end

              exposure_data << exposure
            end
          end

          if exposure_data.empty?
            puts "No historical vulnerabilities found"
            return
          end

          output_results(exposure_data)
        end

        def calculate_historical_exposure(ecosystem, package_name, vuln_pkg, last_commit)
          window = find_vulnerability_window(ecosystem, package_name, vuln_pkg)
          return nil unless window

          introducing_change = window[:introducing]
          fixing_change = window[:fixing]

          introduced_at = introducing_change.commit.committed_at
          fixed_at = fixing_change&.commit&.committed_at
          published_at = vuln_pkg.vulnerability&.published_at
          now = Time.now

          total_exposure_days = if introduced_at
                                  end_time = fixed_at || now
                                  ((end_time - introduced_at) / 86400).round
                                end

          post_disclosure_days = if published_at
                                   start_time = [introduced_at, published_at].compact.max
                                   end_time = fixed_at || now
                                   if start_time && end_time > start_time
                                     ((end_time - start_time) / 86400).round
                                   else
                                     0
                                   end
                                 end

          {
            id: vuln_pkg.vulnerability_id,
            severity: vuln_pkg.vulnerability&.severity,
            package_name: package_name,
            package_version: introducing_change.requirement,
            published_at: published_at&.strftime("%Y-%m-%d"),
            introduced_at: introduced_at&.strftime("%Y-%m-%d"),
            introduced_by: format_commit_info(introducing_change.commit),
            fixed_at: fixed_at&.strftime("%Y-%m-%d"),
            fixed_by: fixing_change ? format_commit_info(fixing_change.commit) : nil,
            status: window[:status],
            total_exposure_days: total_exposure_days,
            post_disclosure_days: post_disclosure_days
          }
        end

        def output_results(exposure_data)
          if @options[:format] == "json"
            require "json"
            puts JSON.pretty_generate({
              vulnerabilities: exposure_data,
              summary: compute_exposure_summary(exposure_data)
            })
          elsif @options[:summary]
            output_exposure_summary(exposure_data)
          else
            output_exposure_table(exposure_data)
          end
        end

        def calculate_exposure(vuln, up_to_commit)
          osv_ecosystem = Ecosystems.to_osv(vuln[:ecosystem])
          vuln_pkg = Models::VulnerabilityPackage.first(
            vulnerability_id: vuln[:id],
            ecosystem: osv_ecosystem,
            package_name: vuln[:package_name]
          )

          return nil unless vuln_pkg

          vulnerability = vuln_pkg.vulnerability
          published_at = vulnerability&.published_at

          introduced_change = find_introducing_change(
            vuln[:ecosystem],
            vuln[:package_name],
            vuln_pkg,
            up_to_commit
          )

          introduced_at = introduced_change&.commit&.committed_at

          fixed_change = find_fixing_change(
            vuln[:ecosystem],
            vuln[:package_name],
            vuln_pkg,
            up_to_commit,
            introduced_at
          )

          fixed_at = fixed_change&.commit&.committed_at
          now = Time.now

          total_exposure_days = if introduced_at
                                  end_time = fixed_at || now
                                  ((end_time - introduced_at) / 86400).round
                                end

          post_disclosure_days = if published_at
                                   start_time = [introduced_at, published_at].compact.max
                                   end_time = fixed_at || now
                                   if start_time && end_time > start_time
                                     ((end_time - start_time) / 86400).round
                                   else
                                     0
                                   end
                                 end

          {
            id: vuln[:id],
            severity: vuln[:severity],
            package_name: vuln[:package_name],
            package_version: vuln[:package_version],
            published_at: published_at&.strftime("%Y-%m-%d"),
            introduced_at: introduced_at&.strftime("%Y-%m-%d"),
            introduced_by: introduced_change ? format_commit_info(introduced_change.commit) : nil,
            fixed_at: fixed_at&.strftime("%Y-%m-%d"),
            fixed_by: fixed_change ? format_commit_info(fixed_change.commit) : nil,
            status: fixed_at ? "fixed" : "ongoing",
            total_exposure_days: total_exposure_days,
            post_disclosure_days: post_disclosure_days
          }
        end

        def compute_exposure_summary(data)
          return {} if data.empty?

          fixed = data.select { |d| d[:status] == "fixed" }
          ongoing = data.select { |d| d[:status] == "ongoing" }

          post_disclosure_times = fixed.map { |d| d[:post_disclosure_days] }.compact
          mean_remediation = post_disclosure_times.empty? ? nil : (post_disclosure_times.sum.to_f / post_disclosure_times.size).round(1)
          median_remediation = median(post_disclosure_times)

          oldest_ongoing = ongoing.map { |d| d[:post_disclosure_days] }.compact.max

          by_severity = {}
          %w[critical high medium low].each do |sev|
            sev_fixed = fixed.select { |d| d[:severity]&.downcase == sev }
            sev_times = sev_fixed.map { |d| d[:post_disclosure_days] }.compact
            next if sev_times.empty?

            by_severity[sev] = (sev_times.sum.to_f / sev_times.size).round(1)
          end

          {
            total_vulnerabilities: data.size,
            fixed_count: fixed.size,
            ongoing_count: ongoing.size,
            mean_remediation_days: mean_remediation,
            median_remediation_days: median_remediation,
            oldest_ongoing_days: oldest_ongoing,
            by_severity: by_severity
          }
        end

        def output_exposure_summary(data)
          summary = compute_exposure_summary(data)

          # Build stats rows
          rows = []
          rows << ["Total vulnerabilities", summary[:total_vulnerabilities].to_s]
          rows << ["Fixed", summary[:fixed_count].to_s]
          rows << ["Ongoing", summary[:ongoing_count].to_s]

          if summary[:fixed_count].positive?
            rows << ["Median remediation", "#{summary[:median_remediation_days] || 'N/A'} days"]
            rows << ["Mean remediation", "#{summary[:mean_remediation_days] || 'N/A'} days"]
          end

          if summary[:oldest_ongoing_days]
            rows << ["Oldest unpatched", "#{summary[:oldest_ongoing_days]} days"]
          end

          # Add severity breakdown
          summary[:by_severity].each do |sev, avg|
            rows << ["#{sev.capitalize} (avg)", "#{avg} days"]
          end

          output_stats_table(rows)
        end

        def output_stats_table(rows)
          return if rows.empty?

          max_label = rows.map { |r| r[0].length }.max
          max_value = rows.map { |r| r[1].length }.max

          width = max_label + max_value + 7
          border = "+" + ("-" * (width - 2)) + "+"

          puts border
          rows.each do |label, value|
            puts "| #{label.ljust(max_label)} | #{value.rjust(max_value)} |"
          end
          puts border
        end

        def output_exposure_table(data)
          max_pkg = data.map { |d| d[:package_name].length }.max || 10
          max_id = data.map { |d| d[:id].length }.max || 15

          header = "#{"Package".ljust(max_pkg)}  #{"CVE".ljust(max_id)}  Introduced   Fixed        Exposed  Post-Disclosure"
          puts header
          puts "-" * header.length

          data.sort_by { |d| [SEVERITY_ORDER[d[:severity]&.downcase] || 4, d[:package_name]] }.each do |row|
            pkg = row[:package_name].ljust(max_pkg)
            id = row[:id].ljust(max_id)
            introduced = (row[:introduced_at] || "unknown").ljust(10)
            fixed = row[:status] == "fixed" ? row[:fixed_at].ljust(10) : "-".ljust(10)
            exposed = row[:total_exposure_days] ? "#{row[:total_exposure_days]}d".ljust(7) : "?".ljust(7)

            post = if row[:status] == "ongoing" && row[:post_disclosure_days]
                     "#{row[:post_disclosure_days]}d (ongoing)"
                   elsif row[:post_disclosure_days]
                     "#{row[:post_disclosure_days]}d"
                   else
                     "?"
                   end

            line = "#{pkg}  #{id}  #{introduced}   #{fixed}   #{exposed}  #{post}"
            colored_line = case row[:severity]&.downcase
                           when "critical", "high" then Color.red(line)
                           when "medium" then Color.yellow(line)
                           when "low" then Color.cyan(line)
                           else line
                           end
            puts colored_line
          end

          puts ""
          output_exposure_summary(data)
        end

        def median(values)
          return nil if values.empty?

          sorted = values.sort
          mid = sorted.size / 2
          if sorted.size.odd?
            sorted[mid]
          else
            ((sorted[mid - 1] + sorted[mid]) / 2.0).round(1)
          end
        end
        end
      end
    end
  end
end
