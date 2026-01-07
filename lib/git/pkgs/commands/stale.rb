# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Stale
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          branch_name = @options[:branch] || repo.default_branch
          branch = Models::Branch.first(name: branch_name)

          error "No analysis found for branch '#{branch_name}'. Run 'git pkgs init' first." unless branch&.last_analyzed_sha

          current_commit = Models::Commit.first(sha: branch.last_analyzed_sha)

          return empty_result("No dependencies found") unless current_commit

          # Only look at lockfile dependencies (actual resolved versions, not constraints)
          snapshots = current_commit.dependency_snapshots_dataset
            .eager(:manifest)
            .join(:manifests, id: :manifest_id)
            .where(Sequel[:manifests][:kind] => "lockfile")

          if @options[:ecosystem]
            snapshots = snapshots.where(Sequel[:dependency_snapshots][:ecosystem] => @options[:ecosystem])
          end

          snapshots = snapshots.all

          if snapshots.empty?
            empty_result "No dependencies found"
            return
          end

          # Batch fetch all changes for current dependencies
          snapshot_keys = snapshots.map { |s| [s.name, s.manifest_id] }.to_set
          manifest_ids = snapshots.map(&:manifest_id).uniq
          names = snapshots.map(&:name).uniq

          all_changes = Models::DependencyChange
            .eager(:commit)
            .where(manifest_id: manifest_ids, name: names)
            .to_a

          # Group by (name, manifest_id) and find latest by committed_at
          latest_by_key = {}
          all_changes.each do |change|
            key = [change.name, change.manifest_id]
            next unless snapshot_keys.include?(key)

            existing = latest_by_key[key]
            if existing.nil? || change.commit.committed_at > existing.commit.committed_at
              latest_by_key[key] = change
            end
          end

          # Find last update for each dependency
          outdated_data = []
          now = Time.now

          snapshots.each do |snapshot|
            last_change = latest_by_key[[snapshot.name, snapshot.manifest_id]]

            next unless last_change

            days_since_update = ((now - last_change.commit.committed_at) / 86400).to_i

            outdated_data << {
              name: snapshot.name,
              ecosystem: snapshot.ecosystem,
              requirement: snapshot.requirement,
              manifest: snapshot.manifest.path,
              last_updated: last_change.commit.committed_at,
              days_ago: days_since_update,
              change_type: last_change.change_type
            }
          end

          # Sort by days since last update (oldest first)
          outdated_data.sort_by! { |d| -d[:days_ago] }

          if @options[:days]
            outdated_data = outdated_data.select { |d| d[:days_ago] >= @options[:days] }
          end

          if outdated_data.empty?
            if @options[:format] == "json"
              require "json"
              puts JSON.pretty_generate([])
            else
              empty_result "All dependencies have been updated recently"
            end
            return
          end

          if @options[:format] == "json"
            output_json(outdated_data)
          else
            paginate { output_text(outdated_data) }
          end
        end

        def output_text(outdated_data)
          puts "Dependencies by last update:"
          puts

          max_name_len = outdated_data.map { |d| d[:name].length }.max
          max_version_len = outdated_data.map { |d| d[:requirement].to_s.length }.max

          outdated_data.each do |dep|
            date = dep[:last_updated].strftime("%Y-%m-%d")
            days = "#{dep[:days_ago]} days ago"
            puts "#{dep[:name].ljust(max_name_len)}  #{dep[:requirement].to_s.ljust(max_version_len)}  #{date}  (#{days})"
          end
        end

        def output_json(outdated_data)
          require "json"

          data = outdated_data.map do |dep|
            {
              name: dep[:name],
              ecosystem: dep[:ecosystem],
              requirement: dep[:requirement],
              manifest: dep[:manifest],
              last_updated: dep[:last_updated].iso8601,
              days_ago: dep[:days_ago]
            }
          end

          puts JSON.pretty_generate(data)
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs stale [options]"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-b", "--branch=NAME", "Branch to analyze") do |v|
              options[:branch] = v
            end

            opts.on("-d", "--days=N", Integer, "Only show deps not updated in N days") do |v|
              options[:days] = v
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
