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
          if @options[:ecosystems]
            output_ecosystems
            return
          end

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
            if snapshot_commits > 0
              puts "  Coverage: #{ratio}% (1 snapshot per ~#{(total_dep_commits / snapshot_commits)} changes)"
            else
              puts "  Coverage: #{ratio}%"
            end
          end
        end

        def output_ecosystems
          require "bibliothecary"

          all_ecosystems = Bibliothecary::Parsers.constants.map do |c|
            parser = Bibliothecary::Parsers.const_get(c)
            parser.platform_name if parser.respond_to?(:platform_name)
          end.compact.sort

          configured = Config.ecosystems
          filtering = configured.any?

          puts "Available Ecosystems"
          puts "=" * 40
          puts

          enabled_ecos = []
          disabled_ecos = []

          all_ecosystems.each do |eco|
            if Config.filter_ecosystem?(eco)
              remote = Config.remote_ecosystem?(eco)
              disabled_ecos << { name: eco, remote: remote }
            else
              enabled_ecos << eco
            end
          end

          puts "Enabled:"
          if enabled_ecos.any?
            enabled_ecos.each { |eco| puts "  #{Color.green(eco)}" }
          else
            puts "  (none)"
          end

          puts
          puts "Disabled:"
          if disabled_ecos.any?
            disabled_ecos.each do |eco|
              suffix = eco[:remote] ? " (remote)" : ""
              puts "  #{eco[:name]}#{suffix}"
            end
          else
            puts "  (none)"
          end

          puts
          if filtering
            puts "Filtering: only #{configured.join(', ')}"
          else
            puts "All local ecosystems enabled"
          end
          puts "Remote ecosystems require explicit opt-in"
          puts "Configure with: git config --add pkgs.ecosystems <name>"
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
            opts.banner = "Usage: git pkgs info [options]"

            opts.on("--ecosystems", "Show available ecosystems and filter status") do
              options[:ecosystems] = true
            end

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
