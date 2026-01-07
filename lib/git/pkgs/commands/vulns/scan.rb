# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        class Scan
          include Base

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs vulns [ref] [options]"
            opts.separator ""
            opts.separator "Scan dependencies for known vulnerabilities."
            opts.separator ""
            opts.separator "Arguments:"
            opts.separator "  ref                    Git ref to scan (default: HEAD)"
            opts.separator ""
            opts.separator "Subcommands:"
            opts.separator "  sync                   Sync vulnerability data from OSV"
            opts.separator "  blame                  Show who introduced each vulnerability"
            opts.separator "  praise                 Show who fixed vulnerabilities"
            opts.separator "  exposure               Calculate exposure windows and remediation metrics"
            opts.separator "  diff                   Compare vulnerability state between commits"
            opts.separator "  log                    Show commits that introduced or fixed vulns"
            opts.separator "  history                Show vulnerability timeline for a package or CVE"
            opts.separator "  show                   Show details about a specific CVE"
            opts.separator ""
            opts.separator "Options:"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-s", "--severity=LEVEL", "Minimum severity (critical, high, medium, low)") do |v|
              options[:severity] = v
            end

            opts.on("-b", "--branch=NAME", "Branch context for finding snapshots") do |v|
              options[:branch] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json, sarif)") do |v|
              options[:format] = v
            end

            opts.on("--no-pager", "Do not pipe output into a pager") do
              options[:no_pager] = true
            end

            opts.on("--stateless", "Parse manifests directly without database") do
              options[:stateless] = true
            end

            opts.on("-h", "--help", "Show this help") do
              puts opts
              exit
            end
          end

          parser.parse!(@args)
          options[:ref] = @args.shift unless @args.empty?
          options
        end

        def run
          repo = Repository.new
          use_stateless = @options[:stateless] || !Database.exists?(repo.git_dir)

          if use_stateless
            # Use in-memory database for vuln caching in stateless mode
            Database.connect_memory
            deps = get_dependencies_stateless(repo)
          else
            Database.connect(repo.git_dir)
            deps = get_dependencies_with_database(repo)
          end

          if deps.empty?
            empty_result "No dependencies found"
            return
          end

          supported_deps = deps.select { |d| Ecosystems.supported?(d[:ecosystem]) }

          if supported_deps.empty?
            empty_result "No dependencies from supported ecosystems (#{Ecosystems.supported_ecosystems.join(", ")})"
            return
          end

          vulns = scan_for_vulnerabilities(supported_deps)

          if @options[:severity]
            min_level = SEVERITY_ORDER[@options[:severity].downcase] || 4
            vulns = vulns.select { |v| (SEVERITY_ORDER[v[:severity]&.downcase] || 4) <= min_level }
          end

          if vulns.empty?
            puts "No known vulnerabilities found"
            return
          end

          vulns.sort_by! { |v| [SEVERITY_ORDER[v[:severity]&.downcase] || 4, v[:package_name]] }

          case @options[:format]
          when "json"
            require "json"
            puts JSON.pretty_generate(vulns)
          when "sarif"
            output_sarif(vulns, deps)
          else
            output_text(vulns)
          end
        end

        def output_sarif(vulns, deps)
          require "sarif"

          rules = vulns.map do |vuln|
            Sarif::ReportingDescriptor.new(
              id: vuln[:id],
              name: vuln[:id],
              short_description: Sarif::MultiformatMessageString.new(text: vuln[:summary] || vuln[:id]),
              help_uri: "https://osv.dev/vulnerability/#{vuln[:id]}",
              properties: {
                security_severity: severity_score(vuln[:severity])
              }.compact
            )
          end.uniq(&:id)

          results = vulns.map do |vuln|
            locations = deps
              .select { |d| d[:name].downcase == vuln[:package_name].downcase && d[:ecosystem] == vuln[:ecosystem] }
              .map do |dep|
                Sarif::Location.new(
                  physical_location: Sarif::PhysicalLocation.new(
                    artifact_location: Sarif::ArtifactLocation.new(uri: dep[:manifest_path])
                  ),
                  message: Sarif::Message.new(text: "#{dep[:name]} #{dep[:requirement]}")
                )
              end

            Sarif::Result.new(
              rule_id: vuln[:id],
              level: severity_to_sarif_level(vuln[:severity]),
              message: Sarif::Message.new(
                text: "#{vuln[:package_name]} #{vuln[:package_version]} has a known vulnerability: #{vuln[:summary] || vuln[:id]}"
              ),
              locations: locations.empty? ? nil : locations
            )
          end

          log = Sarif::Log.new(
            version: "2.1.0",
            runs: [
              Sarif::Run.new(
                tool: Sarif::Tool.new(
                  driver: Sarif::ToolComponent.new(
                    name: "git-pkgs",
                    version: Git::Pkgs::VERSION,
                    information_uri: "https://github.com/andrew/git-pkgs",
                    rules: rules
                  )
                ),
                results: results
              )
            ]
          )

          puts log.to_json
        end

        def severity_to_sarif_level(severity)
          case severity&.downcase
          when "critical", "high" then "error"
          when "medium" then "warning"
          when "low" then "note"
          else "warning"
          end
        end

        def severity_score(severity)
          case severity&.downcase
          when "critical" then "9.0"
          when "high" then "7.0"
          when "medium" then "4.0"
          when "low" then "1.0"
          end
        end

        def output_text(vulns)
          max_severity = vulns.map { |v| (v[:severity] || "").length }.max
          max_id = vulns.map { |v| v[:id].length }.max
          max_pkg = vulns.map { |v| v[:package_name].length }.max

          vulns.each do |vuln|
            severity = (vuln[:severity] || "unknown").upcase.ljust(max_severity)
            id = vuln[:id].ljust(max_id)
            pkg = "#{vuln[:package_name]} #{vuln[:package_version]}".ljust(max_pkg + 10)
            fixed = vuln[:fixed_versions] ? "(fixed in #{vuln[:fixed_versions]})" : ""

            line = "#{severity}  #{id}  #{pkg}  #{fixed}"

            colored_line = case vuln[:severity]&.downcase
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
