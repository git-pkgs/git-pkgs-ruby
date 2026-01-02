# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Tree
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          # Get the commit to analyze
          commit_sha = @options[:commit] || repo.head_sha
          commit = find_commit_with_snapshot(commit_sha, repo)

          error "No dependency data found for commit #{commit_sha[0, 7]}" unless commit

          # Get current snapshots
          snapshots = commit.dependency_snapshots.includes(:manifest)

          if @options[:ecosystem]
            snapshots = snapshots.where(ecosystem: @options[:ecosystem])
          end

          if snapshots.empty?
            empty_result "No dependencies found"
            return
          end

          # Group by manifest and build tree
          grouped = snapshots.group_by { |s| s.manifest }

          grouped.each do |manifest, deps|
            puts "#{manifest.path} (#{manifest.ecosystem})"
            puts

            # Separate by dependency type
            by_type = deps.group_by { |d| d.dependency_type || "runtime" }

            by_type.each do |type, type_deps|
              puts "  [#{type}]"
              type_deps.sort_by(&:name).each do |dep|
                print_dependency(dep, 2)
              end
              puts
            end
          end

          # Show summary
          puts "Total: #{snapshots.count} dependencies across #{grouped.keys.count} manifest(s)"
        end

        def print_dependency(dep, indent)
          prefix = "  " * indent
          version = dep.requirement || "*"
          puts "#{prefix}#{dep.name} #{version}"

          # If this manifest has lockfile data, we could show transitive deps
          # For now, we just show the direct dependencies
          # Future enhancement: parse lockfiles to show full tree
        end

        def find_commit_with_snapshot(sha, repo)
          commit = Models::Commit.find_by(sha: sha) ||
                   Models::Commit.where("sha LIKE ?", "#{sha}%").first
          return commit if commit&.dependency_snapshots&.any?

          # Find most recent commit with a snapshot
          branch_name = @options[:branch] || repo.default_branch
          branch = Models::Branch.find_by(name: branch_name)
          return nil unless branch

          branch.commits
            .joins(:dependency_snapshots)
            .where("commits.committed_at <= ?", commit&.committed_at || Time.now)
            .order(committed_at: :desc)
            .distinct
            .first
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs tree [options]"

            opts.on("-c", "--commit=SHA", "Show dependencies at specific commit") do |v|
              options[:commit] = v
            end

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-b", "--branch=NAME", "Branch context for finding snapshots") do |v|
              options[:branch] = v
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
