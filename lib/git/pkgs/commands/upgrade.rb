# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Upgrade
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir, check_version: false)

          stored = Database.stored_version || 0
          current = Database::SCHEMA_VERSION

          if stored >= current
            puts "Database is up to date (version #{current})"
            return
          end

          puts "Upgrading database from version #{stored} to #{current}..."
          puts "This requires re-indexing the repository."
          puts

          # Run init --force
          Init.new(["--force"]).run
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs upgrade [options]"

            opts.on("-h", "--help", "Show this help") do
              puts opts
              exit
            end
          end

          parser.parse!(@args)
          options
        end
      end
    end
  end
end
