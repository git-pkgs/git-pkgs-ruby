# frozen_string_literal: true

require "bibliothecary"

module Git
  module Pkgs
    class Analyzer
      attr_reader :repository

      # Common manifest file patterns for quick pre-filtering
      # This avoids calling Bibliothecary.identify_manifests for commits that clearly don't touch manifests
      QUICK_MANIFEST_PATTERNS = %w[
        Gemfile Gemfile.lock gems.rb gems.locked *.gemspec
        package.json package-lock.json yarn.lock npm-shrinkwrap.json pnpm-lock.yaml bun.lock npm-ls.json
        setup.py req*.txt req*.pip requirements/*.txt requirements/*.pip requirements.frozen
        Pipfile Pipfile.lock pyproject.toml poetry.lock uv.lock pylock.toml
        pip-resolved-dependencies.txt pip-dependency-graph.json
        pom.xml ivy.xml build.gradle build.gradle.kts gradle-dependencies-q.txt
        maven-resolved-dependencies.txt sbt-update-full.txt maven-dependency-tree.txt maven-dependency-tree.dot
        Cargo.toml Cargo.lock
        go.mod go.sum glide.yaml glide.lock Godeps Godeps/Godeps.json
        vendor/manifest vendor/vendor.json Gopkg.toml Gopkg.lock go-resolved-dependencies.json
        composer.json composer.lock
        Podfile Podfile.lock *.podspec *.podspec.json
        packages.config packages.lock.json Project.json Project.lock.json
        *.nuspec paket.lock *.csproj project.assets.json
        cyclonedx.xml cyclonedx.json *.cdx.xml *.cdx.json
        *.spdx *.spdx.json
        bower.json bentofile.yaml
        META.json META.yml
        environment.yml environment.yaml
        cog.yaml versions.json MLmodel DESCRIPTION
        pubspec.yaml pubspec.lock
        dub.json dub.sdl
        REQUIRE
        shard.yml shard.lock
        elm-package.json elm_dependencies.json elm-stuff/exact-dependencies.json
        haxelib.json
        action.yml action.yaml .github/workflows/*.yml .github/workflows/*.yaml
        Dockerfile docker-compose*.yml docker-compose*.yaml
        dvc.yaml vcpkg.json
        Brewfile Brewfile.lock.json
        Modelfile
      ].freeze

      QUICK_MANIFEST_REGEX = Regexp.union(
        QUICK_MANIFEST_PATTERNS.map do |pattern|
          if pattern.include?('*')
            Regexp.new(Regexp.escape(pattern).gsub('\\*', '.*'))
          else
            /(?:^|\/)#{Regexp.escape(pattern)}$/
          end
        end
      ).freeze

      def initialize(repository)
        @repository = repository
        @blob_cache = {}
      end

      # Quick check if any paths might be manifests (fast regex check)
      def might_have_manifests?(paths)
        paths.any? { |p| p.match?(QUICK_MANIFEST_REGEX) }
      end

      # Quick check if a commit touches any manifest files
      def has_manifest_changes?(rugged_commit)
        return false if repository.merge_commit?(rugged_commit)

        blob_paths = repository.blob_paths(rugged_commit)
        all_paths = blob_paths.map { |p| p[:path] }

        return false unless might_have_manifests?(all_paths)

        Bibliothecary.identify_manifests(all_paths).any?
      end

      def analyze_commit(rugged_commit, previous_snapshot = {})
        return nil if repository.merge_commit?(rugged_commit)

        blob_paths = repository.blob_paths(rugged_commit)

        added_paths = blob_paths.select { |p| p[:status] == :added }.map { |p| p[:path] }
        modified_paths = blob_paths.select { |p| p[:status] == :modified }.map { |p| p[:path] }
        removed_paths = blob_paths.select { |p| p[:status] == :deleted }.map { |p| p[:path] }

        all_paths = added_paths + modified_paths + removed_paths
        return nil unless might_have_manifests?(all_paths)

        added_manifests = Bibliothecary.identify_manifests(added_paths)
        modified_manifests = Bibliothecary.identify_manifests(modified_paths)
        removed_manifests = Bibliothecary.identify_manifests(removed_paths)

        return nil if added_manifests.empty? && modified_manifests.empty? && removed_manifests.empty?

        changes = []
        new_snapshot = previous_snapshot.dup

        # Process added manifest files
        added_manifests.each do |manifest_path|
          result = parse_manifest_at_commit(rugged_commit, manifest_path)
          next unless result

          result[:dependencies].each do |dep|
            changes << {
              manifest_path: manifest_path,
              ecosystem: result[:platform],
              kind: result[:kind],
              name: dep[:name],
              change_type: "added",
              requirement: dep[:requirement],
              dependency_type: dep[:type]
            }

            key = [manifest_path, dep[:name]]
            new_snapshot[key] = {
              ecosystem: result[:platform],
              kind: result[:kind],
              requirement: dep[:requirement],
              dependency_type: dep[:type]
            }
          end
        end

        # Process modified manifest files
        modified_manifests.each do |manifest_path|
          before_result = parse_manifest_before_commit(rugged_commit, manifest_path)
          after_result = parse_manifest_at_commit(rugged_commit, manifest_path)

          next unless after_result

          before_deps = (before_result&.dig(:dependencies) || []).map { |d| [d[:name], d] }.to_h
          after_deps = (after_result[:dependencies] || []).map { |d| [d[:name], d] }.to_h

          added_names = after_deps.keys - before_deps.keys
          removed_names = before_deps.keys - after_deps.keys
          common_names = after_deps.keys & before_deps.keys

          added_names.each do |name|
            dep = after_deps[name]
            changes << {
              manifest_path: manifest_path,
              ecosystem: after_result[:platform],
              kind: after_result[:kind],
              name: name,
              change_type: "added",
              requirement: dep[:requirement],
              dependency_type: dep[:type]
            }

            key = [manifest_path, name]
            new_snapshot[key] = {
              ecosystem: after_result[:platform],
              kind: after_result[:kind],
              requirement: dep[:requirement],
              dependency_type: dep[:type]
            }
          end

          removed_names.each do |name|
            dep = before_deps[name]
            changes << {
              manifest_path: manifest_path,
              ecosystem: before_result[:platform],
              kind: before_result[:kind],
              name: name,
              change_type: "removed",
              requirement: dep[:requirement],
              dependency_type: dep[:type]
            }

            key = [manifest_path, name]
            new_snapshot.delete(key)
          end

          common_names.each do |name|
            before_dep = before_deps[name]
            after_dep = after_deps[name]

            if before_dep[:requirement] != after_dep[:requirement] || before_dep[:type] != after_dep[:type]
              changes << {
                manifest_path: manifest_path,
                ecosystem: after_result[:platform],
                kind: after_result[:kind],
                name: name,
                change_type: "modified",
                requirement: after_dep[:requirement],
                previous_requirement: before_dep[:requirement],
                dependency_type: after_dep[:type]
              }

              key = [manifest_path, name]
              new_snapshot[key] = {
                ecosystem: after_result[:platform],
                kind: after_result[:kind],
                requirement: after_dep[:requirement],
                dependency_type: after_dep[:type]
              }
            end
          end
        end

        # Process removed manifest files
        removed_manifests.each do |manifest_path|
          result = parse_manifest_before_commit(rugged_commit, manifest_path)
          next unless result

          result[:dependencies].each do |dep|
            changes << {
              manifest_path: manifest_path,
              ecosystem: result[:platform],
              kind: result[:kind],
              name: dep[:name],
              change_type: "removed",
              requirement: dep[:requirement],
              dependency_type: dep[:type]
            }

            key = [manifest_path, dep[:name]]
            new_snapshot.delete(key)
          end
        end

        {
          changes: changes,
          snapshot: new_snapshot
        }
      end

      # Cache stats for debugging
      def cache_stats
        hits = @blob_cache.values.count { |v| v[:hits] > 0 }
        total = @blob_cache.size
        { cached_blobs: total, blobs_with_hits: hits }
      end

      def parse_manifest_at_commit(rugged_commit, manifest_path)
        blob_oid = repository.blob_oid_at_commit(rugged_commit, manifest_path)
        return nil unless blob_oid

        parse_manifest_by_oid(blob_oid, manifest_path)
      end

      def parse_manifest_before_commit(rugged_commit, manifest_path)
        return nil if rugged_commit.parents.empty?

        blob_oid = repository.blob_oid_at_commit(rugged_commit.parents[0], manifest_path)
        return nil unless blob_oid

        parse_manifest_by_oid(blob_oid, manifest_path)
      end

      def parse_manifest_by_oid(blob_oid, manifest_path)
        cache_key = "#{blob_oid}:#{manifest_path}"

        if @blob_cache.key?(cache_key)
          @blob_cache[cache_key][:hits] += 1
          return @blob_cache[cache_key][:result]
        end

        content = repository.blob_content(blob_oid)
        return nil unless content

        result = Bibliothecary.analyse_file(manifest_path, content).first
        @blob_cache[cache_key] = { result: result, hits: 0 }
        result
      end
    end
  end
end
