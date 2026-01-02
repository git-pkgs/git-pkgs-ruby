# frozen_string_literal: true

require "optparse"

module Git
  module Pkgs
    class CLI
      COMMANDS = %w[init update hooks info list tree history search why blame outdated stats diff branch show].freeze

      def self.run(args)
        new(args).run
      end

      def initialize(args)
        @args = args.dup
        @options = {}
      end

      def run
        command = @args.shift

        case command
        when nil, "-h", "--help", "help"
          print_help
        when "-v", "--version", "version"
          puts "git-pkgs #{Git::Pkgs::VERSION}"
        when *COMMANDS
          run_command(command)
        else
          $stderr.puts "Unknown command: #{command}"
          $stderr.puts "Run 'git pkgs help' for usage"
          exit 1
        end
      end

      def run_command(command)
        command_class = Commands.const_get(command.capitalize.gsub(/_([a-z])/) { $1.upcase })
        command_class.new(@args).run
      rescue NameError
        $stderr.puts "Command '#{command}' not yet implemented"
        exit 1
      end

      def print_help
        puts <<~HELP
          Usage: git pkgs <command> [options]

          Commands:
            init      Initialize the package database for this repository
            update    Update the database with new commits
            hooks     Manage git hooks for auto-updating
            info      Show database size and row counts
            branch    Manage tracked branches
            list      List dependencies at a commit
            tree      Show dependency tree grouped by type
            history   Show the history of a package
            search    Find a dependency across all history
            why       Explain why a dependency exists
            blame     Show who added each dependency
            outdated  Show dependencies that haven't been updated
            stats     Show dependency statistics
            diff      Show dependency changes between commits
            show      Show dependency changes in a commit

          Options:
            -h, --help     Show this help message
            -v, --version  Show version

          Run 'git pkgs <command> --help' for command-specific options.
        HELP
      end
    end
  end
end
