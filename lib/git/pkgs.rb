# frozen_string_literal: true

require_relative "pkgs/version"
require_relative "pkgs/output"
require_relative "pkgs/color"
require_relative "pkgs/config"
require_relative "pkgs/cli"
require_relative "pkgs/database"
require_relative "pkgs/repository"
require_relative "pkgs/analyzer"
require_relative "pkgs/ecosystems"
require_relative "pkgs/osv_client"

require_relative "pkgs/purl_helper"
require_relative "pkgs/models/branch"
require_relative "pkgs/models/branch_commit"
require_relative "pkgs/models/commit"
require_relative "pkgs/models/manifest"
require_relative "pkgs/models/dependency_change"
require_relative "pkgs/models/dependency_snapshot"
require_relative "pkgs/models/package"
require_relative "pkgs/models/version"
require_relative "pkgs/models/vulnerability"
require_relative "pkgs/models/vulnerability_package"

require_relative "pkgs/commands/init"
require_relative "pkgs/commands/update"
require_relative "pkgs/commands/hooks"
require_relative "pkgs/commands/info"
require_relative "pkgs/commands/list"
require_relative "pkgs/commands/history"
require_relative "pkgs/commands/why"
require_relative "pkgs/commands/blame"
require_relative "pkgs/commands/stale"
require_relative "pkgs/commands/stats"
require_relative "pkgs/commands/diff"
require_relative "pkgs/commands/tree"
require_relative "pkgs/commands/branch"
require_relative "pkgs/commands/search"
require_relative "pkgs/commands/show"
require_relative "pkgs/commands/where"
require_relative "pkgs/commands/log"
require_relative "pkgs/commands/upgrade"
require_relative "pkgs/commands/schema"
require_relative "pkgs/commands/diff_driver"
require_relative "pkgs/commands/completions"
require_relative "pkgs/commands/vulns"

module Git
  module Pkgs
    class Error < StandardError; end
    class NotInitializedError < Error; end
    class NotInGitRepoError < Error; end

    class << self
      attr_accessor :quiet, :git_dir, :work_tree, :db_path, :batch_size, :snapshot_interval, :threads

      # Parse dependencies from a single manifest or lockfile.
      # Returns nil if the file is not recognized as a manifest.
      #
      # @param path [String] file path (used for format detection)
      # @param content [String] file contents
      # @return [Hash, nil] parsed manifest with :platform, :path, :kind, :dependencies keys
      def parse_file(path, content)
        Config.configure_bibliothecary
        result = Bibliothecary.analyse_file(path, content).first
        return nil unless result
        return nil if Config.filter_ecosystem?(result[:platform])

        result
      end

      # Parse dependencies from multiple files.
      # Returns only files that are recognized as manifests.
      #
      # @param files [Hash<String, String>] hash of path => content
      # @return [Array<Hash>] array of parsed manifests
      def parse_files(files)
        Config.configure_bibliothecary
        files.filter_map do |path, content|
          result = Bibliothecary.analyse_file(path, content).first
          next unless result
          next if Config.filter_ecosystem?(result[:platform])

          result
        end
      end

      # Diff dependencies between two versions of a manifest file.
      # Returns added, modified, and removed dependencies.
      #
      # @param path [String] file path (used for format detection)
      # @param old_content [String] previous file contents (empty string for new files)
      # @param new_content [String] current file contents (empty string for deleted files)
      # @return [Hash] with :added, :modified, :removed arrays and :platform, :path keys
      def diff_file(path, old_content, new_content)
        Config.configure_bibliothecary

        old_result = old_content.empty? ? nil : Bibliothecary.analyse_file(path, old_content).first
        new_result = new_content.empty? ? nil : Bibliothecary.analyse_file(path, new_content).first

        platform = new_result&.dig(:platform) || old_result&.dig(:platform)
        return nil unless platform
        return nil if Config.filter_ecosystem?(platform)

        old_deps = (old_result&.dig(:dependencies) || []).map { |d| [d[:name], d] }.to_h
        new_deps = (new_result&.dig(:dependencies) || []).map { |d| [d[:name], d] }.to_h

        added = (new_deps.keys - old_deps.keys).map { |n| new_deps[n] }
        removed = (old_deps.keys - new_deps.keys).map { |n| old_deps[n] }
        modified = (old_deps.keys & new_deps.keys).filter_map do |name|
          old_dep = old_deps[name]
          new_dep = new_deps[name]
          next if old_dep[:requirement] == new_dep[:requirement] && old_dep[:type] == new_dep[:type]

          new_dep.to_h.merge(previous_requirement: old_dep[:requirement])
        end

        {
          path: path,
          platform: platform,
          kind: new_result&.dig(:kind) || old_result&.dig(:kind),
          added: added,
          modified: modified,
          removed: removed
        }
      end

      def configure_from_env
        @git_dir ||= presence(ENV["GIT_DIR"])
        @work_tree ||= presence(ENV["GIT_WORK_TREE"])
        @db_path ||= presence(ENV["GIT_PKGS_DB"])
        @batch_size ||= int_presence(ENV["GIT_PKGS_BATCH_SIZE"])
        @snapshot_interval ||= int_presence(ENV["GIT_PKGS_SNAPSHOT_INTERVAL"])
        @threads ||= int_presence(ENV["GIT_PKGS_THREADS"])
      end

      def reset_config!
        @quiet = false
        @git_dir = nil
        @work_tree = nil
        @db_path = nil
        @batch_size = nil
        @snapshot_interval = nil
        @threads = nil
      end

      def int_presence(value)
        value && !value.empty? ? value.to_i : nil
      end

      def presence(value)
        value && !value.empty? ? value : nil
      end
    end
    self.quiet = false
  end
end
