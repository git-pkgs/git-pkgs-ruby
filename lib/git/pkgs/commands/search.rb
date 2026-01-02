# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Search
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          pattern = @args.first

          error "Usage: git pkgs search <pattern>" unless pattern

          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          # Search for dependencies matching the pattern
          query = Models::DependencyChange
            .joins(:manifest)
            .where("dependency_changes.name LIKE ?", "%#{pattern}%")

          if @options[:ecosystem]
            query = query.where(ecosystem: @options[:ecosystem])
          end

          if @options[:direct]
            query = query.where(manifests: { kind: "manifest" })
          end

          # Get unique dependency names
          matches = query.distinct.pluck(:name, :ecosystem)

          if matches.empty?
            empty_result "No dependencies found matching '#{pattern}'"
            return
          end

          if @options[:format] == "json"
            output_json(matches, pattern)
          else
            output_text(matches, pattern)
          end
        end

        def output_text(matches, pattern)
          puts "Dependencies matching '#{pattern}':"
          puts

          matches.group_by { |_, platform| platform }.each do |platform, deps|
            puts "#{platform}:"
            deps.each do |name, _|
              summary = dependency_summary(name, platform)
              puts "  #{name}"
              puts "    #{summary}"
            end
            puts
          end
        end

        def output_json(matches, pattern)
          require "json"

          results = matches.map do |name, platform|
            changes = Models::DependencyChange
              .where(name: name, ecosystem: platform)
              .includes(:commit)
              .order("commits.committed_at ASC")

            first = changes.first
            last = changes.last
            current = changes.where(change_type: %w[added modified]).last

            {
              name: name,
              ecosystem: platform,
              first_seen: first&.commit&.committed_at&.iso8601,
              last_changed: last&.commit&.committed_at&.iso8601,
              current_version: current&.requirement,
              removed: changes.last&.change_type == "removed",
              total_changes: changes.count
            }
          end

          puts JSON.pretty_generate(results)
        end

        def dependency_summary(name, platform)
          changes = Models::DependencyChange
            .where(name: name, ecosystem: platform)
            .includes(:commit)
            .order("commits.committed_at ASC")

          first = changes.first
          last = changes.last

          parts = []
          parts << "added #{first.commit.committed_at.strftime('%Y-%m-%d')}"

          if last.change_type == "removed"
            parts << "removed #{last.commit.committed_at.strftime('%Y-%m-%d')}"
          else
            current = changes.where(change_type: %w[added modified]).last
            parts << "current: #{current&.requirement || 'unknown'}"
          end

          parts << "#{changes.count} changes"
          parts.join(", ")
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs search <pattern> [options]"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-d", "--direct", "Only show direct dependencies (not from lockfiles)") do
              options[:direct] = true
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
