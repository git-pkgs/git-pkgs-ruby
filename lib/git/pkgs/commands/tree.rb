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

          error "No dependency data for commit #{commit_sha[0, 7]}. Run 'git pkgs update' to index new commits." unless commit

          # Get current snapshots
          snapshots = commit.dependency_snapshots_dataset.eager(:manifest)

          if @options[:ecosystem]
            snapshots = snapshots.where(ecosystem: @options[:ecosystem])
          end

          snapshots_list = snapshots.all

          if snapshots_list.empty?
            empty_result "No dependencies found"
            return
          end

          # Group by manifest and build tree
          grouped = snapshots_list.group_by { |s| s.manifest }

          paginate { output_text(grouped, snapshots_list) }
        end

        def output_text(grouped, snapshots)
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
          commit = Models::Commit.first(sha: sha) ||
                   Models::Commit.where(Sequel.like(:sha, "#{sha}%")).first
          return commit if commit&.dependency_snapshots&.any?

          # Find most recent commit with a snapshot
          branch_name = @options[:branch] || repo.default_branch
          branch = Models::Branch.first(name: branch_name)
          return nil unless branch

          target_time = commit&.committed_at || Time.now
          branch.commits_dataset
            .join(:dependency_snapshots, commit_id: :id)
            .where { Sequel[:commits][:committed_at] <= target_time }
            .order(Sequel.desc(Sequel[:commits][:committed_at]))
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

            opts.on("--no-pager", "Do not pipe output into a pager") do
              options[:no_pager] = true
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
