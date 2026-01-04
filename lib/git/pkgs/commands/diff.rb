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

          from_ref, to_ref = parse_range_argument
          from_ref ||= @options[:from]
          to_ref ||= @options[:to] || "HEAD"

          error "Usage: git pkgs diff <commit>..<commit> or git pkgs diff --from=REF [--to=REF]" unless from_ref

          # Resolve git refs (like HEAD~10) to SHAs
          from_sha = repo.rev_parse(from_ref)
          to_sha = repo.rev_parse(to_ref)

          error "Could not resolve '#{from_ref}'" unless from_sha
          error "Could not resolve '#{to_ref}'" unless to_sha

          from_commit = Models::Commit.find_or_create_from_repo(repo, from_sha)
          to_commit = Models::Commit.find_or_create_from_repo(repo, to_sha)

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

          paginate { output_text(from_commit, to_commit, changes) }
        end

        def output_text(from_commit, to_commit, changes)
          puts "Dependency changes from #{from_commit.short_sha} to #{to_commit.short_sha}:"
          puts

          added = changes.select { |c| c.change_type == "added" }
          modified = changes.select { |c| c.change_type == "modified" }
          removed = changes.select { |c| c.change_type == "removed" }

          if added.any?
            puts Color.green("Added:")
            added.group_by(&:name).each do |name, pkg_changes|
              latest = pkg_changes.last
              puts Color.green("  + #{name} #{latest.requirement} (#{latest.manifest.path})")
            end
            puts
          end

          if modified.any?
            puts Color.yellow("Modified:")
            modified.group_by(&:name).each do |name, pkg_changes|
              first = pkg_changes.first
              latest = pkg_changes.last
              puts Color.yellow("  ~ #{name} #{first.previous_requirement} -> #{latest.requirement}")
            end
            puts
          end

          if removed.any?
            puts Color.red("Removed:")
            removed.group_by(&:name).each do |name, pkg_changes|
              latest = pkg_changes.last
              puts Color.red("  - #{name} (was #{latest.requirement})")
            end
            puts
          end

          # Summary
          added_count = Color.green("+#{added.map(&:name).uniq.count}")
          removed_count = Color.red("-#{removed.map(&:name).uniq.count}")
          modified_count = Color.yellow("~#{modified.map(&:name).uniq.count}")
          puts "Summary: #{added_count} #{removed_count} #{modified_count}"
        end

        def parse_range_argument
          return [nil, nil] if @args.empty?

          arg = @args.first
          return [nil, nil] if arg.start_with?("-")

          if arg.include?("..")
            @args.shift
            parts = arg.split("..", 2)
            [parts[0], parts[1].empty? ? "HEAD" : parts[1]]
          else
            # Single ref means "from that ref to HEAD"
            @args.shift
            [arg, "HEAD"]
          end
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs diff [<from>..<to>] [options]"
            opts.separator ""
            opts.separator "Examples:"
            opts.separator "  git pkgs diff main..feature"
            opts.separator "  git pkgs diff HEAD~10"
            opts.separator "  git pkgs diff --from=v1.0 --to=v2.0"
            opts.separator ""

            opts.on("-f", "--from=REF", "Start commit") do |v|
              options[:from] = v
            end

            opts.on("-t", "--to=REF", "End commit (default: HEAD)") do |v|
              options[:to] = v
            end

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
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
