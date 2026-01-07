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
          use_stateless = @options[:stateless] || !Database.exists?(repo.git_dir)

          sha = repo.rev_parse(ref)
          error "Could not resolve '#{ref}'. Check that the ref exists with 'git rev-parse #{ref}'." unless sha

          if use_stateless
            run_stateless(repo, sha)
          else
            run_with_database(repo, sha)
          end
        end

        def run_stateless(repo, sha)
          rugged_commit = repo.lookup(sha)
          analyzer = Analyzer.new(repo)

          if rugged_commit.parents.empty?
            # First commit - all deps are "added"
            deps = analyzer.dependencies_at_commit(rugged_commit)
            changes = deps.map do |dep|
              {
                name: dep[:name],
                change_type: "added",
                requirement: dep[:requirement],
                ecosystem: dep[:ecosystem],
                manifest_path: dep[:manifest_path]
              }
            end
          else
            diff = analyzer.diff_commits(rugged_commit.parents[0], rugged_commit)
            changes = []
            diff[:added].each { |d| changes << d.merge(change_type: "added") }
            diff[:modified].each { |d| changes << d.merge(change_type: "modified") }
            diff[:removed].each { |d| changes << d.merge(change_type: "removed") }
          end

          if @options[:ecosystem]
            changes = changes.select { |c| c[:ecosystem] == @options[:ecosystem] }
          end

          commit_info = {
            sha: sha,
            short_sha: sha[0..7],
            message: rugged_commit.message,
            author_name: rugged_commit.author[:name],
            author_email: rugged_commit.author[:email],
            committed_at: rugged_commit.time
          }

          if changes.empty?
            empty_result "No dependency changes in #{commit_info[:short_sha]}"
            return
          end

          if @options[:format] == "json"
            output_json_stateless(commit_info, changes)
          else
            paginate { output_text_stateless(commit_info, changes) }
          end
        end

        def run_with_database(repo, sha)
          Database.connect(repo.git_dir)

          commit = Models::Commit.find_or_create_from_repo(repo, sha)
          error "Commit '#{sha[0..7]}' not in database. Run 'git pkgs update' to index new commits." unless commit

          changes = Models::DependencyChange
            .eager(:commit, :manifest)
            .where(commit_id: commit.id)

          if @options[:ecosystem]
            changes = changes.where(ecosystem: @options[:ecosystem])
          end

          changes = changes.all

          if changes.empty?
            empty_result "No dependency changes in #{commit.short_sha}"
            return
          end

          if @options[:format] == "json"
            output_json(commit, changes)
          else
            paginate { output_text(commit, changes) }
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
            puts Color.green("Added:")
            added.each do |change|
              puts Color.green("  + #{change.name} #{change.requirement} (#{change.ecosystem}, #{change.manifest.path})")
            end
            puts
          end

          if modified.any?
            puts Color.yellow("Modified:")
            modified.each do |change|
              puts Color.yellow("  ~ #{change.name} #{change.previous_requirement} -> #{change.requirement} (#{change.ecosystem}, #{change.manifest.path})")
            end
            puts
          end

          if removed.any?
            puts Color.red("Removed:")
            removed.each do |change|
              puts Color.red("  - #{change.name} #{change.requirement} (#{change.ecosystem}, #{change.manifest.path})")
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

        def output_text_stateless(commit_info, changes)
          puts "Commit: #{commit_info[:short_sha]} #{commit_info[:message]&.lines&.first&.strip}"
          puts "Author: #{commit_info[:author_name]} <#{commit_info[:author_email]}>"
          puts "Date:   #{commit_info[:committed_at].strftime("%Y-%m-%d")}"
          puts

          added = changes.select { |c| c[:change_type] == "added" }
          modified = changes.select { |c| c[:change_type] == "modified" }
          removed = changes.select { |c| c[:change_type] == "removed" }

          if added.any?
            puts Color.green("Added:")
            added.each do |change|
              puts Color.green("  + #{change[:name]} #{change[:requirement]} (#{change[:ecosystem]}, #{change[:manifest_path]})")
            end
            puts
          end

          if modified.any?
            puts Color.yellow("Modified:")
            modified.each do |change|
              puts Color.yellow("  ~ #{change[:name]} #{change[:previous_requirement]} -> #{change[:requirement]} (#{change[:ecosystem]}, #{change[:manifest_path]})")
            end
            puts
          end

          if removed.any?
            puts Color.red("Removed:")
            removed.each do |change|
              puts Color.red("  - #{change[:name]} #{change[:requirement]} (#{change[:ecosystem]}, #{change[:manifest_path]})")
            end
            puts
          end
        end

        def output_json_stateless(commit_info, changes)
          require "json"

          data = {
            commit: {
              sha: commit_info[:sha],
              short_sha: commit_info[:short_sha],
              message: commit_info[:message]&.lines&.first&.strip,
              author_name: commit_info[:author_name],
              author_email: commit_info[:author_email],
              date: commit_info[:committed_at].iso8601
            },
            changes: changes.map do |change|
              {
                name: change[:name],
                change_type: change[:change_type],
                requirement: change[:requirement],
                previous_requirement: change[:previous_requirement],
                ecosystem: change[:ecosystem],
                manifest: change[:manifest_path]
              }
            end
          }

          puts JSON.pretty_generate(data)
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
