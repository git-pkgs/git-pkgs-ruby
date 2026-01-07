# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        class Diff
          include Base

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs vulns diff [ref1] [ref2] [options]"
            opts.separator ""
            opts.separator "Compare vulnerability state between two commits."
            opts.separator ""
            opts.separator "Arguments:"
            opts.separator "  ref1                   First git ref (default: HEAD~1)"
            opts.separator "  ref2                   Second git ref (default: HEAD)"
            opts.separator ""
            opts.separator "Examples:"
            opts.separator "  git pkgs vulns diff main feature-branch"
            opts.separator "  git pkgs vulns diff v1.0.0 v2.0.0"
            opts.separator "  git pkgs vulns diff HEAD~10"
            opts.separator ""
            opts.separator "Options:"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-s", "--severity=LEVEL", "Minimum severity (critical, high, medium, low)") do |v|
              options[:severity] = v
            end

            opts.on("-b", "--branch=NAME", "Branch context for finding commits") do |v|
              options[:branch] = v
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
          options
        end

        def run
          repo = Repository.new

          unless Database.exists?(repo.git_dir)
            error "No database found. Run 'git pkgs init' first. Diff requires commit history."
          end

          Database.connect(repo.git_dir)

          ref1, ref2 = parse_diff_refs(repo)
          commit1_sha = repo.rev_parse(ref1)
          commit2_sha = repo.rev_parse(ref2)

          commit1 = Models::Commit.first(sha: commit1_sha)
          commit2 = Models::Commit.first(sha: commit2_sha)

          error "Commit #{commit1_sha[0, 7]} not in database. Run 'git pkgs update' first." unless commit1
          error "Commit #{commit2_sha[0, 7]} not in database. Run 'git pkgs update' first." unless commit2

          deps1 = compute_dependencies_at_commit(commit1, repo)
          deps2 = compute_dependencies_at_commit(commit2, repo)

          supported_deps1 = deps1.select { |d| Ecosystems.supported?(d[:ecosystem]) }
          supported_deps2 = deps2.select { |d| Ecosystems.supported?(d[:ecosystem]) }

          vulns1 = scan_for_vulnerabilities(supported_deps1)
          vulns2 = scan_for_vulnerabilities(supported_deps2)

          if @options[:severity]
            min_level = SEVERITY_ORDER[@options[:severity].downcase] || 4
            vulns1 = vulns1.select { |v| (SEVERITY_ORDER[v[:severity]&.downcase] || 4) <= min_level }
            vulns2 = vulns2.select { |v| (SEVERITY_ORDER[v[:severity]&.downcase] || 4) <= min_level }
          end

          vulns1_ids = vulns1.map { |v| v[:id] }.to_set
          vulns2_ids = vulns2.map { |v| v[:id] }.to_set

          added = vulns2.reject { |v| vulns1_ids.include?(v[:id]) }
          removed = vulns1.reject { |v| vulns2_ids.include?(v[:id]) }

          if added.empty? && removed.empty?
            puts "No vulnerability changes between #{ref1} and #{ref2}"
            return
          end

          if @options[:format] == "json"
            require "json"
            puts JSON.pretty_generate({
              from: ref1,
              to: ref2,
              added: added,
              removed: removed
            })
          else
            output_diff_text(added, removed, ref1, ref2)
          end
        end

        def parse_diff_refs(repo)
          args = @args.dup
          ref1 = args.shift
          ref2 = args.shift

          if ref1.nil?
            ref1 = "HEAD~1"
            ref2 = "HEAD"
          elsif ref2.nil?
            ref2 = ref1
            ref1 = "HEAD"
          end

          if ref1.include?("...")
            parts = ref1.split("...")
            ref1 = parts[0]
            ref2 = parts[1]
          elsif ref1.include?("..")
            parts = ref1.split("..")
            ref1 = parts[0]
            ref2 = parts[1]
          end

          [ref1, ref2]
        end

        def output_diff_text(added, removed, ref1, ref2)
          all_vulns = added.map { |v| v.merge(diff_type: :added) } +
                      removed.map { |v| v.merge(diff_type: :removed) }

          all_vulns.sort_by! do |v|
            [SEVERITY_ORDER[v[:severity]&.downcase] || 4, v[:package_name]]
          end

          max_severity = all_vulns.map { |v| (v[:severity] || "").length }.max || 8
          max_id = all_vulns.map { |v| v[:id].length }.max || 15
          max_pkg = all_vulns.map { |v| "#{v[:package_name]} #{v[:package_version]}".length }.max || 20

          all_vulns.each do |vuln|
            prefix = vuln[:diff_type] == :added ? "+" : "-"
            severity = (vuln[:severity] || "unknown").upcase.ljust(max_severity)
            id = vuln[:id].ljust(max_id)
            pkg = "#{vuln[:package_name]} #{vuln[:package_version]}".ljust(max_pkg)
            note = vuln[:diff_type] == :added ? "(introduced in #{ref2})" : "(fixed in #{ref2})"

            color = vuln[:diff_type] == :added ? :red : :green
            line = "#{prefix}#{severity}  #{id}  #{pkg}  #{note}"
            puts Color.send(color, line)
          end
        end
        end
      end
    end
  end
end
