# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Show
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          ref = @args.shift || "HEAD"

          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          sha = repo.rev_parse(ref)
          error "Could not resolve '#{ref}'" unless sha

          commit = find_or_create_commit(repo, sha)
          error "Commit '#{sha[0..7]}' not found" unless commit

          changes = Models::DependencyChange
            .includes(:commit, :manifest)
            .where(commit_id: commit.id)

          if @options[:ecosystem]
            changes = changes.where(ecosystem: @options[:ecosystem])
          end

          if changes.empty?
            empty_result "No dependency changes in #{commit.short_sha}"
            return
          end

          if @options[:format] == "json"
            output_json(commit, changes)
          else
            output_text(commit, changes)
          end
        end

        def output_text(commit, changes)
          puts "Commit: #{commit.short_sha} #{commit.message&.lines&.first&.strip}"
          puts "Author: #{commit.author_name} <#{commit.author_email}>"
          puts "Date:   #{commit.committed_at.strftime("%Y-%m-%d")}"
          puts

          added = changes.select { |c| c.change_type == "added" }
          modified = changes.select { |c| c.change_type == "modified" }
          removed = changes.select { |c| c.change_type == "removed" }

          if added.any?
            puts "Added:"
            added.each do |change|
              puts "  #{change.name} #{change.requirement} (#{change.ecosystem}, #{change.manifest.path})"
            end
            puts
          end

          if modified.any?
            puts "Modified:"
            modified.each do |change|
              puts "  #{change.name} #{change.previous_requirement} -> #{change.requirement} (#{change.ecosystem}, #{change.manifest.path})"
            end
            puts
          end

          if removed.any?
            puts "Removed:"
            removed.each do |change|
              puts "  #{change.name} #{change.requirement} (#{change.ecosystem}, #{change.manifest.path})"
            end
            puts
          end
        end

        def output_json(commit, changes)
          require "json"

          data = {
            commit: {
              sha: commit.sha,
              short_sha: commit.short_sha,
              message: commit.message&.lines&.first&.strip,
              author_name: commit.author_name,
              author_email: commit.author_email,
              date: commit.committed_at.iso8601
            },
            changes: changes.map do |change|
              {
                name: change.name,
                change_type: change.change_type,
                requirement: change.requirement,
                previous_requirement: change.previous_requirement,
                ecosystem: change.ecosystem,
                manifest: change.manifest.path
              }
            end
          }

          puts JSON.pretty_generate(data)
        end

        def find_or_create_commit(repo, sha)
          commit = Models::Commit.find_by(sha: sha) ||
                   Models::Commit.where("sha LIKE ?", "#{sha}%").first
          return commit if commit

          rugged_commit = repo.lookup(sha)
          return nil unless rugged_commit

          Models::Commit.create!(
            sha: rugged_commit.oid,
            message: rugged_commit.message,
            author_name: rugged_commit.author[:name],
            author_email: rugged_commit.author[:email],
            committed_at: rugged_commit.time,
            has_dependency_changes: false
          )
        rescue Rugged::OdbError
          nil
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs show [commit] [options]"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
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
