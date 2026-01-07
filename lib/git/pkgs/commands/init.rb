# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Init
        include Output

        DEFAULT_BATCH_SIZE = 500
        DEFAULT_SNAPSHOT_INTERVAL = 50

        def batch_size
          Git::Pkgs.batch_size || DEFAULT_BATCH_SIZE
        end

        def snapshot_interval
          Git::Pkgs.snapshot_interval || DEFAULT_SNAPSHOT_INTERVAL
        end

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new

          branch_name = @options[:branch] || repo.default_branch
          error "Branch '#{branch_name}' not found. Check 'git branch -a' for available branches." unless repo.branch_exists?(branch_name)

          if Database.exists?(repo.git_dir) && !@options[:force]
            info "Database already exists. Use --force to rebuild."
            return
          end

          Database.drop if @options[:force]
          Database.connect(repo.git_dir, check_version: false)
          Database.create_schema(with_indexes: false)
          Database.optimize_for_bulk_writes

          branch = Models::Branch.find_or_create(branch_name)
          analyzer = Analyzer.new(repo)

          print "Analyzing #{branch_name}..." unless Git::Pkgs.quiet

          walker = repo.walk(branch_name, @options[:since])
          commits = walker.to_a
          total = commits.size
          repo.prefetch_blob_paths(commits)

          stats = bulk_process_commits(commits, branch, analyzer, total)

          branch.update(last_analyzed_sha: repo.branch_target(branch_name))

          Database.create_bulk_indexes
          Database.optimize_for_reads

          info "\r#{' ' * 40}\rAnalyzed #{branch_name}: #{total} commits (#{stats[:dependency_commits]} with dependency changes)"

          unless @options[:no_hooks]
            Commands::Hooks.new([]).install_hooks(repo, quiet: true)
          end
        end

        def bulk_process_commits(commits, branch, analyzer, total)
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
          last_processed_sha = nil

          flush = lambda do
            return if pending_commits.empty?

            Database.db.transaction do
              Models::Commit.dataset.multi_insert(pending_commits) if pending_commits.any?

              commit_ids = Models::Commit
                .where(sha: pending_commits.map { |c| c[:sha] })
                .select_hash(:sha, :id)

              if pending_branch_commits.any?
                branch_commit_records = pending_branch_commits.map do |bc|
                  { branch_id: bc[:branch_id], commit_id: commit_ids[bc[:sha]], position: bc[:position] }
                end
                Models::BranchCommit.dataset.multi_insert(branch_commit_records)
              end

              if pending_changes.any?
                manifest_ids = Models::Manifest.select_hash(:path, :id)
                change_records = pending_changes.map do |c|
                  {
                    commit_id: commit_ids[c[:sha]],
                    manifest_id: manifest_ids[c[:manifest_path]],
                    name: c[:name],
                    ecosystem: c[:ecosystem],
                    purl: c[:purl],
                    change_type: c[:change_type],
                    requirement: c[:requirement],
                    previous_requirement: c[:previous_requirement],
                    dependency_type: c[:dependency_type],
                    created_at: now,
                    updated_at: now
                  }
                end
                Models::DependencyChange.dataset.multi_insert(change_records)
              end

              if pending_snapshots.any?
                manifest_ids ||= Models::Manifest.select_hash(:path, :id)
                snapshot_records = pending_snapshots.map do |s|
                  {
                    commit_id: commit_ids[s[:sha]],
                    manifest_id: manifest_ids[s[:manifest_path]],
                    name: s[:name],
                    ecosystem: s[:ecosystem],
                    purl: s[:purl],
                    requirement: s[:requirement],
                    dependency_type: s[:dependency_type],
                    created_at: now,
                    updated_at: now
                  }
                end
                Models::DependencySnapshot.dataset.multi_insert(snapshot_records)
              end
            end

            pending_commits.clear
            pending_branch_commits.clear
            pending_changes.clear
            pending_snapshots.clear
          end

          progress_interval = [total / 100, 10].max

          commits.each do |rugged_commit|
            processed += 1
            print "\rProcessing commit #{processed}/#{total}..." if !Git::Pkgs.quiet && (processed % progress_interval == 0 || processed == total)

            next if rugged_commit.parents.length > 1 # skip merge commits

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

            last_processed_sha = rugged_commit.oid

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
                  purl: change[:purl],
                  change_type: change[:change_type],
                  requirement: change[:requirement],
                  previous_requirement: change[:previous_requirement],
                  dependency_type: change[:dependency_type]
                }
              end

              snapshot = result[:snapshot]

              # Store snapshot at intervals
              if dependency_commit_count % snapshot_interval == 0
                snapshot.each do |(manifest_path, name), dep_info|
                  pending_snapshots << {
                    sha: rugged_commit.oid,
                    manifest_path: manifest_path,
                    name: name,
                    ecosystem: dep_info[:ecosystem],
                    purl: dep_info[:purl],
                    requirement: dep_info[:requirement],
                    dependency_type: dep_info[:dependency_type]
                  }
                end
                snapshots_stored += snapshot.size
              end
            end

            flush.call if pending_commits.size >= batch_size
          end

          # Always store final snapshot for the last processed commit
          if snapshot.any? && last_processed_sha
            unless pending_snapshots.any? { |s| s[:sha] == last_processed_sha }
              snapshot.each do |(manifest_path, name), dep_info|
                pending_snapshots << {
                  sha: last_processed_sha,
                  manifest_path: manifest_path,
                  name: name,
                  ecosystem: dep_info[:ecosystem],
                  purl: dep_info[:purl],
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

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs init [options]"

            opts.on("-b", "--branch=NAME", "Branch to analyze (default: default branch)") do |v|
              options[:branch] = v
            end

            opts.on("-s", "--since=SHA", "Start from specific commit") do |v|
              options[:since] = v
            end

            opts.on("-f", "--force", "Rebuild database from scratch") do
              options[:force] = true
            end

            opts.on("--no-hooks", "Skip installing git hooks") do
              options[:no_hooks] = true
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
