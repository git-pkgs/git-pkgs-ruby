# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Blame
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          # Get current dependencies at the last analyzed commit
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

          # For each current dependency, find who added it
          blame_data = []

          snapshots.each do |snapshot|
            added_change = Models::DependencyChange
              .includes(:commit)
              .where(name: snapshot.name, manifest: snapshot.manifest)
              .added
              .order("commits.committed_at ASC")
              .first

            next unless added_change

            commit = added_change.commit
            author = best_author(commit)

            blame_data << {
              name: snapshot.name,
              ecosystem: snapshot.ecosystem,
              requirement: snapshot.requirement,
              manifest: snapshot.manifest.path,
              author: author,
              date: commit.committed_at,
              sha: commit.short_sha
            }
          end

          if @options[:format] == "json"
            require "json"
            json_data = blame_data.map do |d|
              d.merge(date: d[:date].iso8601)
            end
            puts JSON.pretty_generate(json_data)
          else
            grouped = blame_data.group_by { |d| [d[:manifest], d[:ecosystem]] }

            grouped.each do |(manifest, ecosystem), deps|
              puts "#{manifest} (#{ecosystem}):"

              max_name_len = deps.map { |d| d[:name].length }.max
              max_author_len = deps.map { |d| d[:author].length }.max

              deps.sort_by { |d| d[:name] }.each do |dep|
                date = dep[:date].strftime("%Y-%m-%d")
                puts "  #{dep[:name].ljust(max_name_len)}  #{dep[:author].ljust(max_author_len)}  #{date}  #{dep[:sha]}"
              end
              puts
            end
          end
        end

        def best_author(commit)
          authors = [commit.author_name] + parse_coauthors(commit.message)

          # Prefer human authors over bots
          human = authors.find { |a| !bot_author?(a) }
          human || authors.first
        end

        def parse_coauthors(message)
          return [] unless message

          message.scan(/^Co-authored-by:\s*(.+?)\s*<[^>]+>/i).flatten
        end

        def bot_author?(name)
          name =~ /\[bot\]$|^dependabot|^renovate|^github-actions/i
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs blame [options]"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-b", "--branch=NAME", "Branch to analyze") do |v|
              options[:branch] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
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
