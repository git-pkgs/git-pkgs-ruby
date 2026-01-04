# frozen_string_literal: true

require "bibliothecary"

module Git
  module Pkgs
    module Config
      # Ecosystems that require remote parsing services - disabled by default
      REMOTE_ECOSYSTEMS = %w[carthage clojars hackage hex swiftpm].freeze

      # File patterns ignored by default (SBOM formats not supported)
      DEFAULT_IGNORED_FILES = %w[
        cyclonedx.xml
        cyclonedx.json
        *.cdx.xml
        *.cdx.json
        *.spdx
        *.spdx.json
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
        platform_lower = platform.to_s.downcase

        # Remote ecosystems are disabled unless explicitly enabled
        if REMOTE_ECOSYSTEMS.include?(platform_lower)
          return !ecosystems.map(&:downcase).include?(platform_lower)
        end

        # If no filter configured, allow all non-remote ecosystems
        return false if ecosystems.empty?

        # Otherwise, only allow explicitly listed ecosystems
        !ecosystems.map(&:downcase).include?(platform_lower)
      end

      def self.remote_ecosystem?(platform)
        REMOTE_ECOSYSTEMS.include?(platform.to_s.downcase)
      end

      def self.reset!
        @ignored_dirs = nil
        @ignored_files = nil
        @ecosystems = nil
      end

      def self.read_config_list(key)
        `git config --get-all #{key} 2>/dev/null`.split("\n").map(&:strip).reject(&:empty?)
      end
    end
  end
end
