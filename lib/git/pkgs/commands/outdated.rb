# frozen_string_literal: true

require "optparse"

module Git
  module Pkgs
    module Commands
      class Outdated
        include Output

        def self.description
          "Show packages with newer versions available"
        end

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs outdated [options]"
            opts.separator ""
            opts.separator "Show packages that have newer versions available in their registries."
            opts.separator ""
            opts.separator "Options:"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-r", "--ref=REF", "Git ref to check (default: HEAD)") do |v|
              options[:ref] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
            end

            opts.on("--major", "Show only major version updates") do
              options[:major_only] = true
            end

            opts.on("--minor", "Show only minor or major updates (skip patch)") do
              options[:minor_only] = true
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

          deps_with_versions = Analyzer.lockfile_dependencies(deps).select do |dep|
            dep[:requirement] && !dep[:requirement].match?(/[<>=~^]/)
          end

          if deps_with_versions.empty?
            empty_result "No dependencies with pinned versions found"
            return
          end

          packages_to_check = deps_with_versions.map do |dep|
            purl = PurlHelper.build_purl(ecosystem: dep[:ecosystem], name: dep[:name]).to_s
            {
              purl: purl,
              name: dep[:name],
              ecosystem: dep[:ecosystem],
              current_version: dep[:requirement],
              manifest_path: dep[:manifest_path]
            }
          end.uniq { |p| p[:purl] }

          enrich_packages(packages_to_check.map { |p| p[:purl] })

          outdated = []
          packages_to_check.each do |pkg|
            db_pkg = Models::Package.first(purl: pkg[:purl])
            next unless db_pkg&.latest_version

            latest = db_pkg.latest_version
            current = pkg[:current_version]

            next if current == latest

            update_type = classify_update(current, latest)
            next if @options[:major_only] && update_type != :major
            next if @options[:minor_only] && update_type == :patch

            outdated << pkg.merge(
              latest_version: latest,
              update_type: update_type
            )
          end

          if outdated.empty?
            puts "All packages are up to date"
            return
          end

          type_order = { major: 0, minor: 1, patch: 2, unknown: 3 }
          outdated.sort_by! { |o| [type_order[o[:update_type]], o[:name]] }

          if @options[:format] == "json"
            require "json"
            puts JSON.pretty_generate(outdated)
          else
            output_text(outdated)
          end
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

        def classify_update(current, latest)
          current_parts = parse_version(current)
          latest_parts = parse_version(latest)

          return :unknown if current_parts.nil? || latest_parts.nil?

          if latest_parts[0] > current_parts[0]
            :major
          elsif latest_parts[1] > current_parts[1]
            :minor
          elsif latest_parts[2] > current_parts[2]
            :patch
          else
            :unknown
          end
        end

        def parse_version(version)
          cleaned = version.to_s.sub(/^v/i, "")
          parts = cleaned.split(".").first(3).map { |p| p.to_i }
          return nil if parts.empty?

          parts + [0] * (3 - parts.length)
        end

        def output_text(outdated)
          max_name = outdated.map { |o| o[:name].length }.max || 20
          max_current = outdated.map { |o| o[:current_version].length }.max || 10
          max_latest = outdated.map { |o| o[:latest_version].length }.max || 10

          outdated.each do |pkg|
            name = pkg[:name].ljust(max_name)
            current = pkg[:current_version].ljust(max_current)
            latest = pkg[:latest_version].ljust(max_latest)
            update = pkg[:update_type].to_s

            line = "#{name}  #{current}  ->  #{latest}  (#{update})"

            colored = case pkg[:update_type]
                      when :major then Color.red(line)
                      when :minor then Color.yellow(line)
                      when :patch then Color.cyan(line)
                      else line
                      end

            puts colored
          end

          puts ""
          summary = "#{outdated.size} outdated package#{"s" if outdated.size != 1}"
          by_type = outdated.group_by { |o| o[:update_type] }
          parts = []
          parts << "#{by_type[:major].size} major" if by_type[:major]&.any?
          parts << "#{by_type[:minor].size} minor" if by_type[:minor]&.any?
          parts << "#{by_type[:patch].size} patch" if by_type[:patch]&.any?
          puts "#{summary}: #{parts.join(", ")}" if parts.any?
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
