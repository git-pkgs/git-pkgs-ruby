# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class List
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          commit_sha = @options[:commit] || repo.head_sha
          target_commit = Models::Commit.first(sha: commit_sha)

          error "Commit #{commit_sha[0, 7]} not in database. Run 'git pkgs update' to index new commits." unless target_commit

          deps = compute_dependencies_at_commit(target_commit, repo)

          # Apply filters
          if @options[:manifest]
            deps = deps.select { |d| d[:manifest_path] == @options[:manifest] }
          end

          if @options[:ecosystem]
            deps = deps.select { |d| d[:ecosystem] == @options[:ecosystem] }
          end

          if @options[:type]
            deps = deps.select { |d| d[:dependency_type] == @options[:type] }
          end

          if deps.empty?
            empty_result "No dependencies found"
            return
          end

          if @options[:format] == "json"
            require "json"
            puts JSON.pretty_generate(deps)
          else
            paginate { output_text(deps) }
          end
        end

        def output_text(deps)
          grouped = deps.group_by { |d| [d[:manifest_path], d[:ecosystem]] }

          grouped.each do |(path, platform), manifest_deps|
            puts "#{path} (#{platform}):"
            manifest_deps.sort_by { |d| d[:name] }.each do |dep|
              type_suffix = dep[:dependency_type] ? " [#{dep[:dependency_type]}]" : ""
              puts "  #{dep[:name]} #{dep[:requirement]}#{type_suffix}"
            end
            puts
          end
        end

        def compute_dependencies_at_commit(target_commit, repo)
          branch_name = @options[:branch] || repo.default_branch
          branch = Models::Branch.first(name: branch_name)
          return [] unless branch

          # Find the nearest snapshot commit before or at target
          snapshot_commit = branch.commits_dataset
            .join(:dependency_snapshots, commit_id: :id)
            .where { Sequel[:commits][:committed_at] <= target_commit.committed_at }
            .order(Sequel.desc(Sequel[:commits][:committed_at]))
            .distinct
            .first

          # Build initial state from snapshot
          deps = {}
          if snapshot_commit
            snapshot_commit.dependency_snapshots.each do |s|
              key = [s.manifest.path, s.name]
              deps[key] = {
                manifest_path: s.manifest.path,
                name: s.name,
                ecosystem: s.ecosystem,
                requirement: s.requirement,
                dependency_type: s.dependency_type
              }
            end
          end

          # Replay changes from snapshot to target
          if snapshot_commit && snapshot_commit.id != target_commit.id
            commit_ids = branch.commits_dataset.select_map(:id)
            changes = Models::DependencyChange
              .join(:commits, id: :commit_id)
              .where(Sequel[:commits][:id] => commit_ids)
              .where { Sequel[:commits][:committed_at] > snapshot_commit.committed_at }
              .where { Sequel[:commits][:committed_at] <= target_commit.committed_at }
              .order(Sequel[:commits][:committed_at])
              .eager(:manifest)
              .all

            changes.each do |change|
              key = [change.manifest.path, change.name]
              case change.change_type
              when "added", "modified"
                deps[key] = {
                  manifest_path: change.manifest.path,
                  name: change.name,
                  ecosystem: change.ecosystem,
                  requirement: change.requirement,
                  dependency_type: change.dependency_type
                }
              when "removed"
                deps.delete(key)
              end
            end
          end

          deps.values
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs list [options]"

            opts.on("-c", "--commit=SHA", "Show dependencies at specific commit") do |v|
              options[:commit] = v
            end

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem (npm, rubygems, etc.)") do |v|
              options[:ecosystem] = v
            end

            opts.on("-m", "--manifest=PATH", "Filter by manifest path") do |v|
              options[:manifest] = v
            end

            opts.on("-t", "--type=TYPE", "Filter by dependency type") do |v|
              options[:type] = v
            end

            opts.on("-b", "--branch=NAME", "Branch context for finding snapshots") do |v|
              options[:branch] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
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
