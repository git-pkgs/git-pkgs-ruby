# frozen_string_literal: true

require "bibliothecary"
require "open3"

module Git
  module Pkgs
    module Config
      # File patterns ignored by default (SBOM formats not supported, go.sum is checksums only)
      DEFAULT_IGNORED_FILES = %w[
        cyclonedx.xml
        cyclonedx.json
        *.cdx.xml
        *.cdx.json
        *.spdx
        *.spdx.json
        go.sum
      ].freeze

      def self.ignored_dirs
        @ignored_dirs ||= read_config_list("pkgs.ignoredDirs")
      end

      def self.ignored_files
        @ignored_files ||= read_config_list("pkgs.ignoredFiles")
      end

      def self.ecosystems
        @ecosystems ||= read_config_list("pkgs.ecosystems")
      end

      def self.configure_bibliothecary
        dirs = ignored_dirs
        files = DEFAULT_IGNORED_FILES + ignored_files

        Bibliothecary.configure do |config|
          config.ignored_dirs += dirs unless dirs.empty?
          config.ignored_files += files
        end
      end

      def self.filter_ecosystem?(platform)
        return false if ecosystems.empty?

        platform_lower = platform.to_s.downcase
        !ecosystems.map(&:downcase).include?(platform_lower)
      end

      def self.reset!
        @ignored_dirs = nil
        @ignored_files = nil
        @ecosystems = nil
      end

      def self.read_config_list(key)
        args = if Git::Pkgs.work_tree
                 ["git", "-C", Git::Pkgs.work_tree.to_s, "config", "--get-all", key.to_s]
               else
                 ["git", "config", "--get-all", key.to_s]
               end
        stdout, _stderr, _status = Open3.capture3(*args)
        stdout.split("\n").map(&:strip).reject(&:empty?)
      end
    end
  end
end
