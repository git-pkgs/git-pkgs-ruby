# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Diff
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          from_ref = @options[:from]
          to_ref = @options[:to] || "HEAD"

          error "Usage: git pkgs diff --from=REF [--to=REF]" unless from_ref

          # Resolve git refs (like HEAD~10) to SHAs
          from_sha = repo.rev_parse(from_ref)
          to_sha = repo.rev_parse(to_ref)

          error "Could not resolve '#{from_ref}'" unless from_sha
          error "Could not resolve '#{to_ref}'" unless to_sha

          from_commit = find_or_create_commit(repo, from_sha)
          to_commit = find_or_create_commit(repo, to_sha)

          error "Commit '#{from_sha[0..7]}' not found" unless from_commit
          error "Commit '#{to_sha[0..7]}' not found" unless to_commit

          # Get all changes between the two commits
          changes = Models::DependencyChange
            .includes(:commit, :manifest)
            .joins(:commit)
            .where("commits.committed_at > ? AND commits.committed_at <= ?",
                   from_commit.committed_at, to_commit.committed_at)
            .order("commits.committed_at ASC")

          if @options[:ecosystem]
            changes = changes.where(ecosystem: @options[:ecosystem])
          end

          if changes.empty?
            empty_result "No dependency changes between #{from_commit.short_sha} and #{to_commit.short_sha}"
            return
          end

          puts "Dependency changes from #{from_commit.short_sha} to #{to_commit.short_sha}:"
          puts

          added = changes.select { |c| c.change_type == "added" }
          modified = changes.select { |c| c.change_type == "modified" }
          removed = changes.select { |c| c.change_type == "removed" }

          if added.any?
            puts "Added:"
            added.group_by(&:name).each do |name, pkg_changes|
              latest = pkg_changes.last
              puts "  + #{name} #{latest.requirement} (#{latest.manifest.path})"
            end
            puts
          end

          if modified.any?
            puts "Modified:"
            modified.group_by(&:name).each do |name, pkg_changes|
              first = pkg_changes.first
              latest = pkg_changes.last
              puts "  ~ #{name} #{first.previous_requirement} -> #{latest.requirement}"
            end
            puts
          end

          if removed.any?
            puts "Removed:"
            removed.group_by(&:name).each do |name, pkg_changes|
              latest = pkg_changes.last
              puts "  - #{name} (was #{latest.requirement})"
            end
            puts
          end

          # Summary
          puts "Summary: +#{added.map(&:name).uniq.count} -#{removed.map(&:name).uniq.count} ~#{modified.map(&:name).uniq.count}"
        end

        def find_or_create_commit(repo, sha)
          commit = Models::Commit.find_by(sha: sha) ||
                   Models::Commit.where("sha LIKE ?", "#{sha}%").first
          return commit if commit

          # Lazily insert commit if it exists in git but not in database
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
            opts.banner = "Usage: git pkgs diff --from=REF [--to=REF] [options]"

            opts.on("-f", "--from=REF", "Start commit (required)") do |v|
              options[:from] = v
            end

            opts.on("-t", "--to=REF", "End commit (default: HEAD)") do |v|
              options[:to] = v
            end

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
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
