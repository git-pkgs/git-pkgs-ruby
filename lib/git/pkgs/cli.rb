# frozen_string_literal: true

require "optparse"

module Git
  module Pkgs
    class CLI
      COMMAND_GROUPS = {
        "Setup" => {
          "init" => "Initialize the package database for this repository",
          "update" => "Update the database with new commits",
          "hooks" => "Manage git hooks for auto-updating",
          "upgrade" => "Upgrade database after git-pkgs update",
          "info" => "Show database size and row counts",
          "branch" => "Manage tracked branches",
          "schema" => "Show database schema",
          "diff-driver" => "Install git textconv driver for lockfile diffs"
        },
        "Query" => {
          "list" => "List dependencies at a commit",
          "tree" => "Show dependency tree grouped by type",
          "search" => "Find a dependency across all history",
          "where" => "Show where a package appears in manifest files",
          "why" => "Explain why a dependency exists"
        },
        "History" => {
          "history" => "Show the history of a package",
          "blame" => "Show who added each dependency",
          "log" => "List commits with dependency changes",
          "show" => "Show dependency changes in a commit",
          "diff" => "Show dependency changes between commits"
        },
        "Analysis" => {
          "stats" => "Show dependency statistics",
          "stale" => "Show dependencies that haven't been updated"
        }
      }.freeze

      COMMANDS = COMMAND_GROUPS.values.flat_map(&:keys).freeze
      COMMAND_DESCRIPTIONS = COMMAND_GROUPS.values.reduce({}, :merge).freeze
      ALIASES = { "praise" => "blame", "outdated" => "stale" }.freeze

      def self.run(args)
        new(args).run
      end

      def initialize(args)
        @args = args.dup
        @options = {}
      end

      def run
        parse_global_options

        command = @args.shift

        case command
        when nil, "-h", "--help", "help"
          print_help
        when "-v", "--version", "version"
          puts "git-pkgs #{Git::Pkgs::VERSION}"
        when *COMMANDS, *ALIASES.keys
          run_command(command)
        else
          $stderr.puts "Unknown command: #{command}"
          $stderr.puts "Run 'git pkgs help' for usage"
          exit 1
        end
      end

      def parse_global_options
        while @args.first&.start_with?("-")
          case @args.first
          when "-q", "--quiet"
            Git::Pkgs.quiet = true
            @args.shift
          else
            break
          end
        end
      end

      def run_command(command)
        command = ALIASES.fetch(command, command)
        # Convert kebab-case or snake_case to PascalCase
        class_name = command.split(/[-_]/).map(&:capitalize).join
        command_class = Commands.const_get(class_name)
        command_class.new(@args).run
      rescue NameError
        $stderr.puts "Command '#{command}' not yet implemented"
        exit 1
      end

      def print_help
        puts "Usage: git pkgs <command> [options]"
        puts

        max_cmd_len = COMMANDS.map(&:length).max

        COMMAND_GROUPS.each do |group, commands|
          puts "#{group}:"
          commands.each do |cmd, desc|
            puts "  #{cmd.ljust(max_cmd_len)}  #{desc}"
          end
          puts
        end

        puts "Options:"
        puts "  -h, --help     Show this help message"
        puts "  -v, --version  Show version"
        puts "  -q, --quiet    Suppress informational messages"
        puts
        puts "Run 'git pkgs <command> -h' for command-specific options."
      end
    end
  end
end
