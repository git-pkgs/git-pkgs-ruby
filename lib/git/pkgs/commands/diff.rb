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
          use_stateless = @options[:stateless] || !Database.exists?(repo.git_dir)

          from_ref, to_ref = parse_range_argument
          from_ref ||= @options[:from]
          to_ref ||= @options[:to] || "HEAD"

          error "Usage: git pkgs diff <commit>..<commit> or git pkgs diff --from=REF [--to=REF]" unless from_ref

          # Resolve git refs (like HEAD~10) to SHAs
          from_sha = repo.rev_parse(from_ref)
          to_sha = repo.rev_parse(to_ref)

          error "Could not resolve '#{from_ref}'. Check that the ref exists." unless from_sha
          error "Could not resolve '#{to_ref}'. Check that the ref exists." unless to_sha

          if use_stateless
            run_stateless(repo, from_sha, to_sha)
          else
            run_with_database(repo, from_sha, to_sha)
          end
        end

        def run_stateless(repo, from_sha, to_sha)
          from_commit = repo.lookup(from_sha)
          to_commit = repo.lookup(to_sha)

          analyzer = Analyzer.new(repo)
          diff = analyzer.diff_commits(from_commit, to_commit)

          if @options[:ecosystem]
            diff[:added] = diff[:added].select { |d| d[:ecosystem] == @options[:ecosystem] }
            diff[:modified] = diff[:modified].select { |d| d[:ecosystem] == @options[:ecosystem] }
            diff[:removed] = diff[:removed].select { |d| d[:ecosystem] == @options[:ecosystem] }
          end

          if diff[:added].empty? && diff[:modified].empty? && diff[:removed].empty?
            if @options[:format] == "json"
              require "json"
              puts JSON.pretty_generate({ from: from_sha[0..7], to: to_sha[0..7], added: [], modified: [], removed: [] })
            else
              empty_result "No dependency changes between #{from_sha[0..7]} and #{to_sha[0..7]}"
            end
            return
          end

          if @options[:format] == "json"
            output_json_stateless(from_sha, to_sha, diff)
          else
            paginate { output_text_stateless(from_sha, to_sha, diff) }
          end
        end

        def run_with_database(repo, from_sha, to_sha)
          Database.connect(repo.git_dir)

          from_commit = Models::Commit.find_or_create_from_repo(repo, from_sha)
          to_commit = Models::Commit.find_or_create_from_repo(repo, to_sha)

          error "Commit '#{from_sha[0..7]}' not in database. Run 'git pkgs update' to index new commits." unless from_commit
          error "Commit '#{to_sha[0..7]}' not in database. Run 'git pkgs update' to index new commits." unless to_commit

          # Get all changes between the two commits
          changes = Models::DependencyChange
            .eager(:commit, :manifest)
            .join(:commits, id: :commit_id)
            .where { Sequel[:commits][:committed_at] > from_commit.committed_at }
            .where { Sequel[:commits][:committed_at] <= to_commit.committed_at }
            .order(Sequel[:commits][:committed_at])

          if @options[:ecosystem]
            changes = changes.where(Sequel[:dependency_changes][:ecosystem] => @options[:ecosystem])
          end

          changes_list = changes.all

          if changes_list.empty?
            if @options[:format] == "json"
              require "json"
              puts JSON.pretty_generate({ from: from_commit.short_sha, to: to_commit.short_sha, added: [], modified: [], removed: [] })
            else
              empty_result "No dependency changes between #{from_commit.short_sha} and #{to_commit.short_sha}"
            end
            return
          end

          if @options[:format] == "json"
            output_json(from_commit, to_commit, changes_list)
          else
            paginate { output_text(from_commit, to_commit, changes_list) }
          end
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

        def output_json(from_commit, to_commit, changes)
          require "json"

          added = changes.select { |c| c.change_type == "added" }
          modified = changes.select { |c| c.change_type == "modified" }
          removed = changes.select { |c| c.change_type == "removed" }

          format_change = lambda do |change|
            {
              name: change.name,
              ecosystem: change.ecosystem,
              requirement: change.requirement,
              manifest: change.manifest.path,
              commit: change.commit.short_sha,
              date: change.commit.committed_at.iso8601
            }
          end

          format_modified = lambda do |first, latest|
            {
              name: first.name,
              ecosystem: first.ecosystem,
              previous_requirement: first.previous_requirement,
              requirement: latest.requirement,
              manifest: latest.manifest.path
            }
          end

          data = {
            from: from_commit.short_sha,
            to: to_commit.short_sha,
            added: added.group_by(&:name).map { |_name, pkg_changes| format_change.call(pkg_changes.last) },
            modified: modified.group_by(&:name).map { |_name, pkg_changes| format_modified.call(pkg_changes.first, pkg_changes.last) },
            removed: removed.group_by(&:name).map { |_name, pkg_changes| format_change.call(pkg_changes.last) },
            summary: {
              added: added.map(&:name).uniq.count,
              modified: modified.map(&:name).uniq.count,
              removed: removed.map(&:name).uniq.count
            }
          }

          puts JSON.pretty_generate(data)
        end

        def output_text_stateless(from_sha, to_sha, diff)
          puts "Dependency changes from #{from_sha[0..7]} to #{to_sha[0..7]}:"
          puts

          if diff[:added].any?
            puts Color.green("Added:")
            diff[:added].group_by { |d| d[:name] }.each do |name, pkg_changes|
              latest = pkg_changes.last
              puts Color.green("  + #{name} #{latest[:requirement]} (#{latest[:manifest_path]})")
            end
            puts
          end

          if diff[:modified].any?
            puts Color.yellow("Modified:")
            diff[:modified].group_by { |d| d[:name] }.each do |name, pkg_changes|
              latest = pkg_changes.last
              puts Color.yellow("  ~ #{name} #{latest[:previous_requirement]} -> #{latest[:requirement]}")
            end
            puts
          end

          if diff[:removed].any?
            puts Color.red("Removed:")
            diff[:removed].group_by { |d| d[:name] }.each do |name, pkg_changes|
              latest = pkg_changes.last
              puts Color.red("  - #{name} (was #{latest[:requirement]})")
            end
            puts
          end

          added_count = Color.green("+#{diff[:added].map { |d| d[:name] }.uniq.count}")
          removed_count = Color.red("-#{diff[:removed].map { |d| d[:name] }.uniq.count}")
          modified_count = Color.yellow("~#{diff[:modified].map { |d| d[:name] }.uniq.count}")
          puts "Summary: #{added_count} #{removed_count} #{modified_count}"
        end

        def output_json_stateless(from_sha, to_sha, diff)
          require "json"

          format_change = lambda do |change|
            {
              name: change[:name],
              ecosystem: change[:ecosystem],
              requirement: change[:requirement],
              manifest: change[:manifest_path]
            }
          end

          format_modified = lambda do |change|
            {
              name: change[:name],
              ecosystem: change[:ecosystem],
              previous_requirement: change[:previous_requirement],
              requirement: change[:requirement],
              manifest: change[:manifest_path]
            }
          end

          data = {
            from: from_sha[0..7],
            to: to_sha[0..7],
            added: diff[:added].map { |c| format_change.call(c) },
            modified: diff[:modified].map { |c| format_modified.call(c) },
            removed: diff[:removed].map { |c| format_change.call(c) },
            summary: {
              added: diff[:added].map { |d| d[:name] }.uniq.count,
              modified: diff[:modified].map { |d| d[:name] }.uniq.count,
              removed: diff[:removed].map { |d| d[:name] }.uniq.count
            }
          }

          puts JSON.pretty_generate(data)
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

            opts.on("--from=REF", "Start commit") do |v|
              options[:from] = v
            end

            opts.on("--to=REF", "End commit (default: HEAD)") do |v|
              options[:to] = v
            end

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
            end

            opts.on("--no-pager", "Do not pipe output into a pager") do
              options[:no_pager] = true
            end

            opts.on("--stateless", "Parse manifests directly without database") do
              options[:stateless] = true
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
