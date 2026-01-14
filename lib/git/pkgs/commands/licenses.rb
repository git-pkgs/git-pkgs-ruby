# frozen_string_literal: true

require "optparse"

module Git
  module Pkgs
    module Commands
      class Licenses
        include Output

        PERMISSIVE = %w[
          MIT Apache-2.0 BSD-2-Clause BSD-3-Clause ISC Unlicense CC0-1.0
          0BSD WTFPL Zlib BSL-1.0
        ].freeze

        COPYLEFT = %w[
          GPL-2.0 GPL-3.0 LGPL-2.1 LGPL-3.0 AGPL-3.0 MPL-2.0
          GPL-2.0-only GPL-2.0-or-later GPL-3.0-only GPL-3.0-or-later
          LGPL-2.1-only LGPL-2.1-or-later LGPL-3.0-only LGPL-3.0-or-later
          AGPL-3.0-only AGPL-3.0-or-later
        ].freeze

        def self.description
          "Show licenses for dependencies"
        end

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = { allow: [], deny: [] }

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs licenses [options]"
            opts.separator ""
            opts.separator "Show licenses for dependencies with optional compliance checks."
            opts.separator ""
            opts.separator "Options:"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-r", "--ref=REF", "Git ref to check (default: HEAD)") do |v|
              options[:ref] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json, csv)") do |v|
              options[:format] = v
            end

            opts.on("--allow=LICENSES", "Comma-separated list of allowed licenses") do |v|
              options[:allow] = v.split(",").map(&:strip)
            end

            opts.on("--deny=LICENSES", "Comma-separated list of denied licenses") do |v|
              options[:deny] = v.split(",").map(&:strip)
            end

            opts.on("--permissive", "Only allow permissive licenses (MIT, Apache, BSD, etc.)") do
              options[:permissive] = true
            end

            opts.on("--copyleft", "Flag copyleft licenses (GPL, AGPL, etc.)") do
              options[:copyleft] = true
            end

            opts.on("--unknown", "Flag packages with unknown/missing licenses") do
              options[:unknown] = true
            end

            opts.on("--group", "Group output by license") do
              options[:group] = true
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
          options
        end

        def run
          repo = Repository.new
          use_stateless = @options[:stateless] || !Database.exists?(repo.git_dir)

          if use_stateless
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

          if @options[:ecosystem]
            deps = deps.select { |d| d[:ecosystem].downcase == @options[:ecosystem].downcase }
          end

          deps = Analyzer.pair_manifests_with_lockfiles(deps)

          if deps.empty?
            empty_result "No dependencies found"
            return
          end

          packages = deps.map do |dep|
            purl = PurlHelper.build_purl(ecosystem: dep[:ecosystem], name: dep[:name]).to_s
            {
              purl: purl,
              name: dep[:name],
              ecosystem: dep[:ecosystem],
              version: dep[:requirement],
              manifest_path: dep[:manifest_path]
            }
          end.uniq { |p| p[:purl] }

          enrich_packages(packages.map { |p| p[:purl] })

          packages.each do |pkg|
            db_pkg = Models::Package.first(purl: pkg[:purl])
            pkg[:license] = db_pkg&.license
            pkg[:violation] = check_violation(pkg[:license])
          end

          violations = packages.select { |p| p[:violation] }

          case @options[:format]
          when "json"
            output_json(packages, violations)
          when "csv"
            output_csv(packages)
          else
            if @options[:group]
              output_grouped(packages, violations)
            else
              output_text(packages, violations)
            end
          end

          exit 1 if violations.any?
        end

        def check_violation(license)
          return "unknown" if @options[:unknown] && (license.nil? || license.empty?)

          return nil if license.nil? || license.empty?

          if @options[:permissive]
            return "copyleft" if COPYLEFT.any? { |l| license_matches?(license, l) }
            return "not-permissive" unless PERMISSIVE.any? { |l| license_matches?(license, l) }
          end

          if @options[:copyleft]
            return "copyleft" if COPYLEFT.any? { |l| license_matches?(license, l) }
          end

          if @options[:allow].any?
            return "not-allowed" unless @options[:allow].any? { |l| license_matches?(license, l) }
          end

          if @options[:deny].any?
            return "denied" if @options[:deny].any? { |l| license_matches?(license, l) }
          end

          nil
        end

        def license_matches?(license, pattern)
          license.downcase.include?(pattern.downcase)
        end

        def enrich_packages(purls)
          packages_by_purl = {}
          purls.each do |purl|
            parsed = Purl::PackageURL.parse(purl)
            ecosystem = PurlHelper::ECOSYSTEM_TO_PURL_TYPE.invert[parsed.type] || parsed.type
            pkg = Models::Package.find_or_create_by_purl(
              purl: purl,
              ecosystem: ecosystem,
              name: parsed.name
            )
            packages_by_purl[purl] = pkg
          end

          stale_purls = packages_by_purl.select { |_, pkg| pkg.needs_enrichment? }.keys
          return if stale_purls.empty?

          client = EcosystemsClient.new
          begin
            results = Spinner.with_spinner("Fetching package metadata...") do
              client.bulk_lookup(stale_purls)
            end
            results.each do |purl, data|
              packages_by_purl[purl]&.enrich_from_api(data)
            end
          rescue EcosystemsClient::ApiError => e
            $stderr.puts "Warning: Could not fetch package data: #{e.message}" unless Git::Pkgs.quiet
          end
        end

        def output_text(packages, violations)
          max_name = packages.map { |p| p[:name].length }.max || 20
          max_license = packages.map { |p| (p[:license] || "").length }.max || 10
          max_license = [max_license, 20].min

          packages.sort_by { |p| [p[:license] || "zzz", p[:name]] }.each do |pkg|
            name = pkg[:name].ljust(max_name)
            license = (pkg[:license] || "unknown").ljust(max_license)[0, max_license]
            ecosystem = pkg[:ecosystem]

            line = "#{name}  #{license}  (#{ecosystem})"

            colored = if pkg[:violation]
                        Color.red("#{line}  [#{pkg[:violation]}]")
                      else
                        line
                      end

            puts colored
          end

          output_summary(packages, violations)
        end

        def output_grouped(packages, violations)
          by_license = packages.group_by { |p| p[:license] || "unknown" }

          by_license.sort_by { |license, _| license.downcase }.each do |license, pkgs|
            has_violation = pkgs.any? { |p| p[:violation] }
            header = "#{license} (#{pkgs.size})"
            puts has_violation ? Color.red(header) : Color.bold(header)

            pkgs.sort_by { |p| p[:name] }.each do |pkg|
              puts "  #{pkg[:name]}"
            end
            puts ""
          end

          output_summary(packages, violations)
        end

        def output_summary(packages, violations)
          return unless violations.any?

          puts ""
          puts Color.red("#{violations.size} license violation#{"s" if violations.size != 1} found")
        end

        def output_json(packages, violations)
          require "json"
          puts JSON.pretty_generate({
            packages: packages,
            summary: {
              total: packages.size,
              violations: violations.size,
              by_license: packages.group_by { |p| p[:license] || "unknown" }.transform_values(&:size)
            }
          })
        end

        def output_csv(packages)
          puts "name,ecosystem,version,license,violation"
          packages.sort_by { |p| p[:name] }.each do |pkg|
            puts [
              pkg[:name],
              pkg[:ecosystem],
              pkg[:version],
              pkg[:license] || "",
              pkg[:violation] || ""
            ].map { |v| csv_escape(v) }.join(",")
          end
        end

        def csv_escape(value)
          if value.to_s.include?(",") || value.to_s.include?('"')
            "\"#{value.to_s.gsub('"', '""')}\""
          else
            value.to_s
          end
        end

        def get_dependencies_stateless(repo)
          ref = @options[:ref] || "HEAD"
          commit_sha = repo.rev_parse(ref)
          rugged_commit = repo.lookup(commit_sha)

          error "Could not resolve '#{ref}'" unless rugged_commit

          analyzer = Analyzer.new(repo)
          analyzer.dependencies_at_commit(rugged_commit)
        end

        def get_dependencies_with_database(repo)
          ref = @options[:ref] || "HEAD"
          commit_sha = repo.rev_parse(ref)
          target_commit = Models::Commit.first(sha: commit_sha)

          return get_dependencies_stateless(repo) unless target_commit

          branch_name = repo.default_branch
          branch = Models::Branch.first(name: branch_name)
          return [] unless branch

          compute_dependencies_at_commit(target_commit, branch)
        end

        def compute_dependencies_at_commit(target_commit, branch)
          snapshot_commit = branch.commits_dataset
            .join(:dependency_snapshots, commit_id: :id)
            .where { Sequel[:commits][:committed_at] <= target_commit.committed_at }
            .order(Sequel.desc(Sequel[:commits][:committed_at]))
            .distinct
            .first

          deps = {}
          if snapshot_commit
            snapshot_commit.dependency_snapshots.each do |s|
              key = [s.manifest.path, s.name]
              deps[key] = {
                manifest_path: s.manifest.path,
                manifest_kind: s.manifest.kind,
                name: s.name,
                ecosystem: s.ecosystem,
                requirement: s.requirement,
                dependency_type: s.dependency_type
              }
            end
          end

          if snapshot_commit && snapshot_commit.id != target_commit.id
            commit_ids = branch.commits_dataset.select_map(Sequel[:commits][:id])
            changes = Models::DependencyChange
              .join(:commits, id: :commit_id)
              .where(Sequel[:commits][:id] => commit_ids)
              .where { Sequel[:commits][:committed_at] > snapshot_commit.committed_at }
              .where { Sequel[:commits][:committed_at] <= target_commit.committed_at }
              .order(Sequel[:commits][:committed_at])
              .eager(:manifest)
              .all

            changes.each do |change|
              key = [change.manifest.path, change.name]
              case change.change_type
              when "added", "modified"
                deps[key] = {
                  manifest_path: change.manifest.path,
                  manifest_kind: change.manifest.kind,
                  name: change.name,
                  ecosystem: change.ecosystem,
                  requirement: change.requirement,
                  dependency_type: change.dependency_type
                }
              when "removed"
                deps.delete(key)
              end
            end
          end

          deps.values
        end
      end
    end
  end
end
