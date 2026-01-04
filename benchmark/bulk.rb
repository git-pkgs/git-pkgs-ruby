#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "git/pkgs"
require "benchmark"

repo_path = ARGV[0] || "/Users/andrew/code/octobox"
sample_size = (ARGV[1] || 500).to_i

# In-memory with WAL mode equivalent (journal_mode=memory for in-memory DB)
Git::Pkgs::Database.connect_memory
ActiveRecord::Base.connection.execute("PRAGMA synchronous = OFF")
ActiveRecord::Base.connection.execute("PRAGMA journal_mode = MEMORY")

repo = Git::Pkgs::Repository.new(repo_path)
analyzer = Git::Pkgs::Analyzer.new(repo)

walker = repo.walk(repo.default_branch)
commits = walker.take(sample_size)

puts "Bulk insert benchmark: #{commits.size} commits"
puts "=" * 60

# Pre-collect all data
all_commits = []
all_branch_commits = []
all_changes = []
all_snapshots = []

snapshot = {}
branch = Git::Pkgs::Models::Branch.find_or_create("main")
position = 0
manifests_cache = {}

now = Time.now

collect_time = Benchmark.realtime do
  commits.each do |rugged_commit|
    next if repo.merge_commit?(rugged_commit)
    position += 1

    result = analyzer.analyze_commit(rugged_commit, snapshot)

    all_commits << {
      sha: rugged_commit.oid,
      message: rugged_commit.message,
      author_name: rugged_commit.author[:name],
      author_email: rugged_commit.author[:email],
      committed_at: rugged_commit.time,
      has_dependency_changes: result && result[:changes].any?,
      created_at: now,
      updated_at: now
    }

    all_branch_commits << {
      branch_id: branch.id,
      commit_position: position,  # placeholder, need to resolve after commit insert
      commit_sha: rugged_commit.oid
    }

    next unless result && result[:changes].any?

    result[:changes].each do |change|
      manifest_key = change[:manifest_path]
      unless manifests_cache[manifest_key]
        manifests_cache[manifest_key] = Git::Pkgs::Models::Manifest.find_or_create(
          path: change[:manifest_path],
          platform: change[:platform],
          kind: change[:kind]
        )
      end

      all_changes << {
        commit_sha: rugged_commit.oid,
        manifest_path: manifest_key,
        name: change[:name],
        platform: change[:platform],
        change_type: change[:change_type],
        requirement: change[:requirement],
        previous_requirement: change[:previous_requirement],
        dependency_type: change[:dependency_type],
        created_at: now,
        updated_at: now
      }
    end

    snapshot = result[:snapshot]

    snapshot.each do |(manifest_path, name), dep_info|
      all_snapshots << {
        commit_sha: rugged_commit.oid,
        manifest_path: manifest_path,
        name: name,
        platform: dep_info[:platform],
        requirement: dep_info[:requirement],
        dependency_type: dep_info[:dependency_type],
        created_at: now,
        updated_at: now
      }
    end
  end
end

puts "Collection time: #{collect_time.round(3)}s"
puts "Data collected:"
puts "  Commits: #{all_commits.size}"
puts "  Changes: #{all_changes.size}"
puts "  Snapshots: #{all_snapshots.size}"

# Bulk insert
insert_time = Benchmark.realtime do
  # Insert commits
  Git::Pkgs::Models::Commit.insert_all(all_commits) if all_commits.any?

  # Build SHA -> ID map
  commit_ids = Git::Pkgs::Models::Commit.where(sha: all_commits.map { |c| c[:sha] }).pluck(:sha, :id).to_h
  manifest_ids = Git::Pkgs::Models::Manifest.pluck(:path, :id).to_h

  # Insert branch_commits with resolved IDs
  branch_commit_records = all_branch_commits.map do |bc|
    {
      branch_id: bc[:branch_id],
      commit_id: commit_ids[bc[:commit_sha]],
      position: bc[:commit_position]
    }
  end
  Git::Pkgs::Models::BranchCommit.insert_all(branch_commit_records) if branch_commit_records.any?

  # Insert changes with resolved IDs
  change_records = all_changes.map do |c|
    {
      commit_id: commit_ids[c[:commit_sha]],
      manifest_id: manifest_ids[c[:manifest_path]],
      name: c[:name],
      platform: c[:platform],
      change_type: c[:change_type],
      requirement: c[:requirement],
      previous_requirement: c[:previous_requirement],
      dependency_type: c[:dependency_type],
      created_at: c[:created_at],
      updated_at: c[:updated_at]
    }
  end
  Git::Pkgs::Models::DependencyChange.insert_all(change_records) if change_records.any?

  # Insert snapshots with resolved IDs
  snapshot_records = all_snapshots.map do |s|
    {
      commit_id: commit_ids[s[:commit_sha]],
      manifest_id: manifest_ids[s[:manifest_path]],
      name: s[:name],
      platform: s[:platform],
      requirement: s[:requirement],
      dependency_type: s[:dependency_type],
      created_at: s[:created_at],
      updated_at: s[:updated_at]
    }
  end
  Git::Pkgs::Models::DependencySnapshot.insert_all(snapshot_records) if snapshot_records.any?
end

puts "Insert time: #{insert_time.round(3)}s"

total = collect_time + insert_time
puts "\nTotal: #{total.round(3)}s"
puts "Throughput: #{(all_commits.size / total).round(1)} commits/sec"
