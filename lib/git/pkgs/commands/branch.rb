# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Branch
        include Output

        BATCH_SIZE = 100
        SNAPSHOT_INTERVAL = 20

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          subcommand = @args.shift

          case subcommand
          when "add"
            add_branch
          when "list"
            list_branches
          when "remove", "rm"
            remove_branch
          when nil, "-h", "--help"
            print_help
          else
            error "Unknown subcommand: #{subcommand}. Run 'git pkgs branch --help' for usage"
          end
        end

        def add_branch
          branch_name = @args.shift
          error "Usage: git pkgs branch add <name>" unless branch_name

          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          error "Branch '#{branch_name}' not found. Check 'git branch -a' for available branches." unless repo.branch_exists?(branch_name)

          existing = Models::Branch.find_by(name: branch_name)
          if existing
            info "Branch '#{branch_name}' already tracked (#{existing.commits.count} commits)"
            info "Use 'git pkgs update' to refresh"
            return
          end

          Database.optimize_for_bulk_writes

          branch = Models::Branch.create!(name: branch_name)
          analyzer = Analyzer.new(repo)

          info "Analyzing branch: #{branch_name}"

          walker = repo.walk(branch_name)
          commits = walker.to_a
          total = commits.size

          stats = bulk_process_commits(commits, branch, analyzer, total, repo)

          branch.update(last_analyzed_sha: repo.branch_target(branch_name))

          Database.optimize_for_reads

          info "\rDone!#{' ' * 20}"
          info "Analyzed #{total} commits"
          info "Found #{stats[:dependency_commits]} commits with dependency changes"
          info "Stored #{stats[:snapshots_stored]} snapshots"
        end

        def list_branches
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          branches = Models::Branch.all

          if branches.empty?
            empty_result "No branches tracked"
            return
          end

          puts "Tracked branches:"
          branches.each do |branch|
            commit_count = branch.commits.count
            dep_commits = branch.commits.where(has_dependency_changes: true).count
            last_sha = branch.last_analyzed_sha&.slice(0, 7) || "none"
            puts "  #{branch.name}: #{commit_count} commits (#{dep_commits} with deps), last: #{last_sha}"
          end
        end

        def remove_branch
          branch_name = @args.shift
          error "Usage: git pkgs branch remove <name>" unless branch_name

          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          branch = Models::Branch.find_by(name: branch_name)
          error "Branch '#{branch_name}' not tracked. Run 'git pkgs branch list' to see tracked branches." unless branch

          # Only delete branch_commits, keep shared commits
          count = branch.branch_commits.count
          branch.branch_commits.delete_all
          branch.destroy

          info "Removed branch '#{branch_name}' (#{count} branch-commit links)"
        end

        def bulk_process_commits(commits, branch, analyzer, total, repo)
          now = Time.now
          snapshot = {}
          manifests_cache = {}

          pending_commits = []
          pending_branch_commits = []
          pending_changes = []
          pending_snapshots = []

          dependency_commit_count = 0
          snapshots_stored = 0
          processed = 0

          flush = lambda do
            return if pending_commits.empty?

            ActiveRecord::Base.transaction do
              # Use upsert for commits since they may already exist from other branches
              if pending_commits.any?
                Models::Commit.upsert_all(
                  pending_commits,
                  unique_by: :sha
                )
              end

              commit_ids = Models::Commit
                .where(sha: pending_commits.map { |c| c[:sha] })
                .pluck(:sha, :id).to_h

              if pending_branch_commits.any?
                branch_commit_records = pending_branch_commits.map do |bc|
                  { branch_id: bc[:branch_id], commit_id: commit_ids[bc[:sha]], position: bc[:position] }
                end
                Models::BranchCommit.insert_all(branch_commit_records)
              end

              if pending_changes.any?
                manifest_ids = Models::Manifest.pluck(:path, :id).to_h
                change_records = pending_changes.map do |c|
                  {
                    commit_id: commit_ids[c[:sha]],
                    manifest_id: manifest_ids[c[:manifest_path]],
                    name: c[:name],
                    ecosystem: c[:ecosystem],
                    change_type: c[:change_type],
                    requirement: c[:requirement],
                    previous_requirement: c[:previous_requirement],
                    dependency_type: c[:dependency_type],
                    created_at: now,
                    updated_at: now
                  }
                end
                Models::DependencyChange.insert_all(change_records)
              end

              if pending_snapshots.any?
                manifest_ids ||= Models::Manifest.pluck(:path, :id).to_h
                snapshot_records = pending_snapshots.map do |s|
                  {
                    commit_id: commit_ids[s[:sha]],
                    manifest_id: manifest_ids[s[:manifest_path]],
                    name: s[:name],
                    ecosystem: s[:ecosystem],
                    requirement: s[:requirement],
                    dependency_type: s[:dependency_type],
                    created_at: now,
                    updated_at: now
                  }
                end
                Models::DependencySnapshot.insert_all(snapshot_records)
              end
            end

            pending_commits.clear
            pending_branch_commits.clear
            pending_changes.clear
            pending_snapshots.clear
          end

          commits.each do |rugged_commit|
            processed += 1
            print "\rProcessing commit #{processed}/#{total}..." if !Git::Pkgs.quiet && (processed % 50 == 0 || processed == total)

            next if rugged_commit.parents.length > 1

            result = analyzer.analyze_commit(rugged_commit, snapshot)
            has_changes = result && result[:changes].any?

            pending_commits << {
              sha: rugged_commit.oid,
              message: rugged_commit.message,
              author_name: rugged_commit.author[:name],
              author_email: rugged_commit.author[:email],
              committed_at: rugged_commit.time,
              has_dependency_changes: has_changes,
              created_at: now,
              updated_at: now
            }

            pending_branch_commits << {
              branch_id: branch.id,
              sha: rugged_commit.oid,
              position: processed
            }

            if has_changes
              dependency_commit_count += 1

              result[:changes].each do |change|
                manifest_key = change[:manifest_path]
                unless manifests_cache[manifest_key]
                  manifests_cache[manifest_key] = Models::Manifest.find_or_create(
                    path: change[:manifest_path],
                    ecosystem: change[:ecosystem],
                    kind: change[:kind]
                  )
                end

                pending_changes << {
                  sha: rugged_commit.oid,
                  manifest_path: manifest_key,
                  name: change[:name],
                  ecosystem: change[:ecosystem],
                  change_type: change[:change_type],
                  requirement: change[:requirement],
                  previous_requirement: change[:previous_requirement],
                  dependency_type: change[:dependency_type]
                }
              end

              snapshot = result[:snapshot]

              if dependency_commit_count % SNAPSHOT_INTERVAL == 0
                snapshot.each do |(manifest_path, name), dep_info|
                  pending_snapshots << {
                    sha: rugged_commit.oid,
                    manifest_path: manifest_path,
                    name: name,
                    ecosystem: dep_info[:ecosystem],
                    requirement: dep_info[:requirement],
                    dependency_type: dep_info[:dependency_type]
                  }
                end
                snapshots_stored += snapshot.size
              end
            end

            flush.call if pending_commits.size >= BATCH_SIZE
          end

          if snapshot.any?
            last_sha = commits.last&.oid
            if last_sha && !pending_snapshots.any? { |s| s[:sha] == last_sha }
              snapshot.each do |(manifest_path, name), dep_info|
                pending_snapshots << {
                  sha: last_sha,
                  manifest_path: manifest_path,
                  name: name,
                  ecosystem: dep_info[:ecosystem],
                  requirement: dep_info[:requirement],
                  dependency_type: dep_info[:dependency_type]
                }
              end
              snapshots_stored += snapshot.size
            end
          end

          flush.call

          { dependency_commits: dependency_commit_count, snapshots_stored: snapshots_stored }
        end

        def print_help
          puts <<~HELP
            Usage: git pkgs branch <subcommand> [options]

            Subcommands:
              add <name>      Analyze and track a branch
              list            List tracked branches
              remove <name>   Stop tracking a branch

            Examples:
              git pkgs branch add feature-x
              git pkgs branch list
              git pkgs branch remove feature-x
          HELP
        end

        def parse_options
          options = {}
          options
        end
      end
    end
  end
end
