# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Stats
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

          if @options[:by_author]
            output_by_author
          else
            data = collect_stats(branch, branch_name)

            if @options[:format] == "json"
              require "json"
              puts JSON.pretty_generate(data)
            else
              paginate { output_text(data) }
            end
          end
        end

        def collect_stats(branch, branch_name)
          ecosystem = @options[:ecosystem]
          since_time = @options[:since] ? parse_time(@options[:since]) : nil
          until_time = @options[:until] ? parse_time(@options[:until]) : nil

          commits = branch&.commits || Models::Commit.none
          commits = commits.where("committed_at >= ?", since_time) if since_time
          commits = commits.where("committed_at <= ?", until_time) if until_time

          data = {
            branch: branch_name,
            ecosystem: ecosystem,
            since: @options[:since],
            until: @options[:until],
            commits_analyzed: commits.count,
            commits_with_changes: commits.where(has_dependency_changes: true).count,
            current_dependencies: {},
            changes: {},
            most_changed: [],
            manifests: []
          }

          if branch&.last_analyzed_sha
            current_commit = Models::Commit.find_by(sha: branch.last_analyzed_sha)
            snapshots = current_commit&.dependency_snapshots || []
            snapshots = snapshots.where(ecosystem: ecosystem) if ecosystem

            data[:current_dependencies] = {
              total: snapshots.count,
              by_platform: snapshots.group(:ecosystem).count,
              by_type: snapshots.group(:dependency_type).count
            }
          end

          changes = Models::DependencyChange.joins(:commit)
          changes = changes.where(ecosystem: ecosystem) if ecosystem
          changes = changes.where("commits.committed_at >= ?", since_time) if since_time
          changes = changes.where("commits.committed_at <= ?", until_time) if until_time

          data[:changes] = {
            total: changes.count,
            by_type: changes.group(:change_type).count
          }

          most_changed = changes
            .group(:name, :ecosystem)
            .order("count_all DESC")
            .limit(10)
            .count

          data[:most_changed] = most_changed.map do |(name, eco), count|
            { name: name, ecosystem: eco, changes: count }
          end

          manifests = Models::Manifest.all
          manifests = manifests.where(ecosystem: ecosystem) if ecosystem

          manifest_ids = manifests.pluck(:id)
          change_counts_query = Models::DependencyChange
            .joins(:commit)
            .where(manifest_id: manifest_ids)
          change_counts_query = change_counts_query.where("commits.committed_at >= ?", since_time) if since_time
          change_counts_query = change_counts_query.where("commits.committed_at <= ?", until_time) if until_time
          change_counts = change_counts_query.group(:manifest_id).count

          data[:manifests] = manifests.map do |manifest|
            { path: manifest.path, ecosystem: manifest.ecosystem, changes: change_counts[manifest.id] || 0 }
          end

          top_authors = changes
            .where(change_type: "added")
            .joins(:commit)
            .group("commits.author_name")
            .order("count_all DESC")
            .limit(5)
            .count

          data[:top_authors] = top_authors.map { |name, count| { name: name, added: count } }

          data
        end

        def output_text(data)
          puts "Dependency Statistics"
          puts "=" * 40
          puts

          puts "Branch: #{data[:branch]}"
          puts "Ecosystem: #{data[:ecosystem]}" if data[:ecosystem]
          puts "Since: #{data[:since]}" if data[:since]
          puts "Until: #{data[:until]}" if data[:until]
          puts "Commits analyzed: #{data[:commits_analyzed]}"
          puts "Commits with changes: #{data[:commits_with_changes]}"
          puts

          if data[:current_dependencies][:total]
            puts "Current Dependencies"
            puts "-" * 20
            puts "Total: #{data[:current_dependencies][:total]}"

            data[:current_dependencies][:by_platform].sort_by { |_, c| -c }.each do |ecosystem, count|
              puts "  #{ecosystem}: #{count}"
            end

            by_type = data[:current_dependencies][:by_type]
            if by_type.keys.compact.any?
              puts
              puts "By type:"
              by_type.sort_by { |_, c| -c }.each do |type, count|
                puts "  #{type || 'unknown'}: #{count}"
              end
            end
          end

          puts
          puts "Dependency Changes"
          puts "-" * 20
          puts "Total changes: #{data[:changes][:total]}"
          data[:changes][:by_type].each do |type, count|
            puts "  #{type}: #{count}"
          end

          puts
          puts "Most Changed Dependencies"
          puts "-" * 25
          data[:most_changed].each do |dep|
            puts "  #{dep[:name]} (#{dep[:ecosystem]}): #{dep[:changes]} changes"
          end

          puts
          puts "Manifest Files"
          puts "-" * 14
          data[:manifests].each do |m|
            puts "  #{m[:path]} (#{m[:ecosystem]}): #{m[:changes]} changes"
          end

          if data[:top_authors]&.any?
            puts
            puts "Top Authors (by deps added)"
            puts "-" * 27
            data[:top_authors].each do |author|
              puts "  #{author[:added].to_s.rjust(4)}  #{author[:name]}"
            end
          end
        end

        def output_by_author
          since_time = @options[:since] ? parse_time(@options[:since]) : nil
          until_time = @options[:until] ? parse_time(@options[:until]) : nil

          changes = Models::DependencyChange
            .joins(:commit)
            .where(change_type: "added")

          changes = changes.where(ecosystem: @options[:ecosystem]) if @options[:ecosystem]
          changes = changes.where("commits.committed_at >= ?", since_time) if since_time
          changes = changes.where("commits.committed_at <= ?", until_time) if until_time

          counts = changes
            .group("commits.author_name")
            .order("count_all DESC")
            .limit(@options[:limit] || 20)
            .count

          if counts.empty?
            empty_result "No dependency additions found"
            return
          end

          if @options[:format] == "json"
            require "json"
            data = counts.map { |name, count| { author: name, added: count } }
            puts JSON.pretty_generate(data)
          else
            paginate { output_by_author_text(counts) }
          end
        end

        def output_by_author_text(counts)
          puts "Dependencies Added by Author"
          puts "=" * 40
          puts
          counts.each do |name, count|
            puts "  #{count.to_s.rjust(4)}  #{name}"
          end
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs stats [options]"

            opts.on("-b", "--branch=NAME", "Branch to analyze") do |v|
              options[:branch] = v
            end

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
            end

            opts.on("--since=DATE", "Show changes after date") do |v|
              options[:since] = v
            end

            opts.on("--until=DATE", "Show changes before date") do |v|
              options[:until] = v
            end

            opts.on("--by-author", "Show dependencies added by author") do
              options[:by_author] = true
            end

            opts.on("-n", "--limit=N", Integer, "Limit results (default: 20)") do |v|
              options[:limit] = v
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
