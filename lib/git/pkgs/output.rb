# frozen_string_literal: true

require "json"
require "time"
require_relative "pager"

module Git
  module Pkgs
    module Output
      include Pager

      def parse_time(str)
        Time.parse(str)
      rescue ArgumentError
        error "Invalid date format: #{str}. Use YYYY-MM-DD format."
      end

      # Print informational/status message. Suppressed in quiet mode.
      def info(msg)
        puts msg unless Git::Pkgs.quiet
      end

      # Print error message and exit with code 1.
      # Use for user errors (bad input, invalid refs) and system errors (db missing).
      # When format is :json, outputs JSON to stdout; otherwise outputs text to stderr.
      def error(msg, format: nil)
        format ||= @options[:format] if defined?(@options) && @options.is_a?(Hash)

        if format == "json"
          puts JSON.generate({ error: msg })
        else
          $stderr.puts msg
        end
        exit 1
      end

      # Print informational message for "no results" cases.
      # When format is :json, outputs empty JSON array/object; otherwise outputs text.
      def empty_result(msg, format: nil, json_value: [])
        format ||= @options[:format] if defined?(@options) && @options.is_a?(Hash)

        if format == "json"
          puts JSON.generate(json_value)
        else
          puts msg
        end
      end

      # Standard check for database existence.
      def require_database(repo)
        return if Database.exists?(repo.git_dir)

        error "Database not initialized. Run 'git pkgs init' first."
      end
    end
  end
end
