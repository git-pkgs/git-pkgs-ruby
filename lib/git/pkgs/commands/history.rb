# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class History
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          package_name = @args.shift

          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          changes = Models::DependencyChange
            .eager_graph(:commit, :manifest)
            .order(Sequel[:commit][:committed_at])

          changes = changes.for_package(package_name) if package_name

          if @options[:ecosystem]
            changes = changes.for_platform(@options[:ecosystem])
          end

          if @options[:author]
            author = @options[:author]
            changes = changes.where(
              Sequel.like(Sequel[:commit][:author_name], "%#{author}%") |
              Sequel.like(Sequel[:commit][:author_email], "%#{author}%")
            )
          end

          if @options[:since]
            since_time = parse_time(@options[:since])
            changes = changes.where { Sequel[:commit][:committed_at] >= since_time }
          end

          if @options[:until]
            until_time = parse_time(@options[:until])
            changes = changes.where { Sequel[:commit][:committed_at] <= until_time }
          end

          changes_list = changes.all

          if changes_list.empty?
            msg = package_name ? "No history found for '#{package_name}'" : "No dependency changes found"
            empty_result msg
            return
          end

          if @options[:format] == "json"
            output_json(changes_list)
          else
            paginate { output_text(changes_list, package_name) }
          end
        end

        def output_text(changes, package_name)
          if package_name
            puts "History for #{package_name}:"
          else
            puts "Dependency history:"
          end
          puts

          changes.each do |change|
            commit = change.commit
            date = commit.committed_at.strftime("%Y-%m-%d")

            case change.change_type
            when "added"
              action = Color.green("Added")
              version_info = change.requirement
            when "modified"
              action = Color.yellow("Updated")
              version_info = "#{change.previous_requirement} -> #{change.requirement}"
            when "removed"
              action = Color.red("Removed")
              version_info = change.requirement
            end

            name_prefix = package_name ? "" : "#{change.name} "
            puts "#{date} #{action} #{name_prefix}#{version_info}"
            puts "  Commit: #{commit.short_sha} #{commit.message&.lines&.first&.strip}"
            puts "  Author: #{commit.author_name} <#{commit.author_email}>"
            puts "  Manifest: #{change.manifest.path}"
            puts
          end
        end

        def output_json(changes)
          require "json"

          data = changes.map do |change|
            {
              name: change.name,
              date: change.commit.committed_at.iso8601,
              change_type: change.change_type,
              requirement: change.requirement,
              previous_requirement: change.previous_requirement,
              manifest: change.manifest.path,
              ecosystem: change.ecosystem,
              commit: {
                sha: change.commit.sha,
                message: change.commit.message&.lines&.first&.strip,
                author_name: change.commit.author_name,
                author_email: change.commit.author_email
              }
            }
          end

          puts JSON.pretty_generate(data)
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs history [package] [options]"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
            end

            opts.on("--author=NAME", "Filter by author name or email") do |v|
              options[:author] = v
            end

            opts.on("--since=DATE", "Show changes after date (YYYY-MM-DD)") do |v|
              options[:since] = v
            end

            opts.on("--until=DATE", "Show changes before date (YYYY-MM-DD)") do |v|
              options[:until] = v
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
