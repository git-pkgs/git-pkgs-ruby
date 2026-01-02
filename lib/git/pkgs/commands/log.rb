# frozen_string_literal: true

require "time"

module Git
  module Pkgs
    module Commands
      class Log
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          commits = Models::Commit
            .where(has_dependency_changes: true)
            .order(committed_at: :desc)

          commits = commits.where("author_name LIKE ? OR author_email LIKE ?",
            "%#{@options[:author]}%", "%#{@options[:author]}%") if @options[:author]
          commits = commits.where("committed_at >= ?", parse_time(@options[:since])) if @options[:since]
          commits = commits.where("committed_at <= ?", parse_time(@options[:until])) if @options[:until]

          commits = commits.limit(@options[:limit] || 20)

          if commits.empty?
            empty_result "No commits with dependency changes found"
            return
          end

          if @options[:format] == "json"
            output_json(commits)
          else
            output_text(commits)
          end
        end

        def output_text(commits)
          commits.each do |commit|
            changes = commit.dependency_changes
            changes = changes.where(ecosystem: @options[:ecosystem]) if @options[:ecosystem]
            next if changes.empty?

            puts "#{commit.short_sha} #{commit.message&.lines&.first&.strip}"
            puts "Author: #{commit.author_name} <#{commit.author_email}>"
            puts "Date:   #{commit.committed_at.strftime("%Y-%m-%d")}"
            puts

            added = changes.select { |c| c.change_type == "added" }
            modified = changes.select { |c| c.change_type == "modified" }
            removed = changes.select { |c| c.change_type == "removed" }

            added.each do |change|
              puts "  + #{change.name} #{change.requirement}"
            end

            modified.each do |change|
              puts "  ~ #{change.name} #{change.previous_requirement} -> #{change.requirement}"
            end

            removed.each do |change|
              puts "  - #{change.name}"
            end

            puts
          end
        end

        def output_json(commits)
          require "json"

          data = commits.map do |commit|
            changes = commit.dependency_changes
            changes = changes.where(ecosystem: @options[:ecosystem]) if @options[:ecosystem]

            {
              sha: commit.sha,
              short_sha: commit.short_sha,
              message: commit.message&.lines&.first&.strip,
              author_name: commit.author_name,
              author_email: commit.author_email,
              date: commit.committed_at.iso8601,
              changes: changes.map do |change|
                {
                  name: change.name,
                  change_type: change.change_type,
                  requirement: change.requirement,
                  previous_requirement: change.previous_requirement,
                  ecosystem: change.ecosystem
                }
              end
            }
          end

          puts JSON.pretty_generate(data)
        end

        def parse_time(str)
          Time.parse(str)
        rescue ArgumentError
          error "Invalid date format: #{str}"
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs log [options]"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("--author=NAME", "Filter by author name or email") do |v|
              options[:author] = v
            end

            opts.on("--since=DATE", "Show commits after date") do |v|
              options[:since] = v
            end

            opts.on("--until=DATE", "Show commits before date") do |v|
              options[:until] = v
            end

            opts.on("-n", "--limit=N", Integer, "Limit commits (default: 20)") do |v|
              options[:limit] = v
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
