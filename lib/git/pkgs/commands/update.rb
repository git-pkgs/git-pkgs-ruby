# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Update
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          branch_name = @options[:branch] || repo.default_branch
          branch = Models::Branch.first(name: branch_name)

          error "Branch '#{branch_name}' not in database. Run 'git pkgs init --branch=#{branch_name}' first." unless branch

          since_sha = branch.last_analyzed_sha
          current_sha = repo.branch_target(branch_name)

          if since_sha == current_sha
            info "Already up to date."
            return
          end

          analyzer = Analyzer.new(repo)

          # Get current snapshot from last analyzed commit
          last_commit = Models::Commit.first(sha: since_sha)
          snapshot = {}

          if last_commit
            last_commit.dependency_snapshots.each do |s|
              key = [s.manifest.path, s.name]
              snapshot[key] = {
                ecosystem: s.ecosystem,
                purl: s.purl,
                requirement: s.requirement,
                dependency_type: s.dependency_type
              }
            end
          end

          walker = repo.walk(branch_name, since_sha)
          commits = walker.to_a
          total = commits.size
          repo.prefetch_blob_paths(commits)

          processed = 0
          dependency_commits = 0
          last_position = Models::BranchCommit.where(branch: branch).max(:position) || 0

          print "Updating #{branch_name}..." unless Git::Pkgs.quiet

          Database.db.transaction do
            commits.each do |rugged_commit|
              processed += 1

              result = analyzer.analyze_commit(rugged_commit, snapshot)

              commit = Models::Commit.find_or_create_from_rugged(rugged_commit)
              Models::BranchCommit.find_or_create(
                branch: branch,
                commit: commit
              ) do |bc|
                bc.position = last_position + processed
              end

              if result && result[:changes].any?
                dependency_commits += 1
                commit.update(has_dependency_changes: true)

                result[:changes].each do |change|
                  manifest = Models::Manifest.find_or_create(
                    path: change[:manifest_path],
                    ecosystem: change[:ecosystem],
                    kind: change[:kind]
                  )

                  Models::DependencyChange.create(
                    commit: commit,
                    manifest: manifest,
                    name: change[:name],
                    ecosystem: change[:ecosystem],
                    purl: change[:purl],
                    change_type: change[:change_type],
                    requirement: change[:requirement],
                    previous_requirement: change[:previous_requirement],
                    dependency_type: change[:dependency_type]
                  )
                end

                snapshot = result[:snapshot]

                snapshot.each do |(manifest_path, name), dep_info|
                  manifest = Models::Manifest.first(path: manifest_path)
                  Models::DependencySnapshot.find_or_create(
                    commit: commit,
                    manifest: manifest,
                    name: name
                  ) do |s|
                    s.ecosystem = dep_info[:ecosystem]
                    s.purl = dep_info[:purl]
                    s.requirement = dep_info[:requirement]
                    s.dependency_type = dep_info[:dependency_type]
                  end
                end
              end
            end

            branch.update(last_analyzed_sha: current_sha)
          end

          info "\r#{' ' * 40}\rUpdated #{branch_name}: #{total} commits (#{dependency_commits} with dependency changes)"
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs update [options]"

            opts.on("-b", "--branch=NAME", "Branch to update (default: default branch)") do |v|
              options[:branch] = v
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
