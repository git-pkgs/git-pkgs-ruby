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
          branch = Models::Branch.find_by(name: branch_name)

          error "No analysis found for branch '#{branch_name}'" unless branch&.last_analyzed_sha

          current_commit = Models::Commit.find_by(sha: branch.last_analyzed_sha)
          snapshots = current_commit&.dependency_snapshots&.includes(:manifest) || []

          if @options[:ecosystem]
            snapshots = snapshots.where(ecosystem: @options[:ecosystem])
          end

          if snapshots.empty?
            empty_result "No dependencies found"
            return
          end

          # Find last update for each dependency
          outdated_data = []

          snapshots.each do |snapshot|
            last_change = Models::DependencyChange
              .includes(:commit)
              .where(name: snapshot.name, manifest: snapshot.manifest)
              .order("commits.committed_at DESC")
              .first

            next unless last_change

            days_since_update = ((Time.now - last_change.commit.committed_at) / 86400).to_i

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
            empty_result "All dependencies have been updated recently"
            return
          end

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
