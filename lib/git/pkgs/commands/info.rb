# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Info
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          db_path = Database.path(repo.git_dir)
          Database.connect(repo.git_dir)

          puts "Database Info"
          puts "=" * 40
          puts

          # File info
          db_size = File.size(db_path)
          puts "Location: #{db_path}"
          puts "Size: #{format_size(db_size)}"
          puts

          # Row counts
          puts "Row Counts"
          puts "-" * 40
          counts = {
            "Branches" => Models::Branch.count,
            "Commits" => Models::Commit.count,
            "Branch-Commits" => Models::BranchCommit.count,
            "Manifests" => Models::Manifest.count,
            "Dependency Changes" => Models::DependencyChange.count,
            "Dependency Snapshots" => Models::DependencySnapshot.count
          }

          counts.each do |name, count|
            puts "  #{name.ljust(22)} #{count.to_s.rjust(10)}"
          end
          puts "  #{'-' * 34}"
          puts "  #{'Total'.ljust(22)} #{counts.values.sum.to_s.rjust(10)}"
          puts

          # Branch info
          puts "Branches"
          puts "-" * 40
          Models::Branch.all.each do |branch|
            commit_count = branch.commits.count
            last_sha = branch.last_analyzed_sha&.slice(0, 7) || "none"
            puts "  #{branch.name}: #{commit_count} commits (last: #{last_sha})"
          end
          puts

          # Snapshot coverage
          puts "Snapshot Coverage"
          puts "-" * 40
          total_dep_commits = Models::Commit.where(has_dependency_changes: true).count
          snapshot_commits = Models::Commit
            .joins(:dependency_snapshots)
            .distinct
            .count
          puts "  Commits with dependency changes: #{total_dep_commits}"
          puts "  Commits with snapshots: #{snapshot_commits}"
          if total_dep_commits > 0
            ratio = (snapshot_commits.to_f / total_dep_commits * 100).round(1)
            puts "  Coverage: #{ratio}% (1 snapshot per ~#{(total_dep_commits.to_f / snapshot_commits).round(0)} changes)"
          end
        end

        def format_size(bytes)
          units = %w[B KB MB GB]
          unit_index = 0
          size = bytes.to_f

          while size >= 1024 && unit_index < units.length - 1
            size /= 1024
            unit_index += 1
          end

          "#{size.round(1)} #{units[unit_index]}"
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs info"

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
