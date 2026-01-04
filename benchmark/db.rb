#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "git/pkgs"
require "benchmark"

repo_path = ARGV[0] || "/Users/andrew/code/octobox"
sample_size = (ARGV[1] || 200).to_i

Git::Pkgs::Database.connect_memory

repo = Git::Pkgs::Repository.new(repo_path)
analyzer = Git::Pkgs::Analyzer.new(repo)

walker = repo.walk(repo.default_branch)
commits = walker.take(sample_size)

puts "DB operation breakdown: #{commits.size} commits"
puts "=" * 60

timings = {
  commit_create: 0.0,
  branch_commit_create: 0.0,
  commit_update: 0.0,
  manifest_find_create: 0.0,
  change_create: 0.0,
  snapshot_create: 0.0
}

counts = {
  commits: 0,
  branch_commits: 0,
  changes: 0,
  snapshots: 0
}

snapshot = {}
branch = Git::Pkgs::Models::Branch.find_or_create("main")
position = 0

commits.each do |rugged_commit|
  next if repo.merge_commit?(rugged_commit)
  position += 1

  result = analyzer.analyze_commit(rugged_commit, snapshot)

  commit = nil
  timings[:commit_create] += Benchmark.realtime do
    commit = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)
  end
  counts[:commits] += 1

  timings[:branch_commit_create] += Benchmark.realtime do
    Git::Pkgs::Models::BranchCommit.find_or_create_by(
      branch: branch,
      commit: commit,
      position: position
    )
  end
  counts[:branch_commits] += 1

  next unless result && result[:changes].any?

  timings[:commit_update] += Benchmark.realtime do
    commit.update(has_dependency_changes: true)
  end

  result[:changes].each do |change|
    manifest = nil
    timings[:manifest_find_create] += Benchmark.realtime do
      manifest = Git::Pkgs::Models::Manifest.find_or_create(
        path: change[:manifest_path],
        platform: change[:platform],
        kind: change[:kind]
      )
    end

    timings[:change_create] += Benchmark.realtime do
      Git::Pkgs::Models::DependencyChange.create!(
        commit: commit,
        manifest: manifest,
        name: change[:name],
        platform: change[:platform],
        change_type: change[:change_type],
        requirement: change[:requirement],
        previous_requirement: change[:previous_requirement],
        dependency_type: change[:dependency_type]
      )
    end
    counts[:changes] += 1
  end

  snapshot = result[:snapshot]

  snapshot.each do |(manifest_path, name), dep_info|
    timings[:snapshot_create] += Benchmark.realtime do
      manifest = Git::Pkgs::Models::Manifest.find_by(path: manifest_path)
      Git::Pkgs::Models::DependencySnapshot.find_or_create_by(
        commit: commit,
        manifest: manifest,
        name: name
      ) do |s|
        s.platform = dep_info[:platform]
        s.requirement = dep_info[:requirement]
        s.dependency_type = dep_info[:dependency_type]
      end
    end
    counts[:snapshots] += 1
  end
end

total = timings.values.sum

puts "\nDB operation breakdown:"
puts "-" * 60
timings.each do |op, time|
  pct = total > 0 ? (time / total * 100).round(1) : 0
  puts "  #{op.to_s.ljust(22)} #{time.round(3).to_s.rjust(8)}s  (#{pct}%)"
end
puts "-" * 60
puts "  #{'Total'.ljust(22)} #{total.round(3).to_s.rjust(8)}s"

puts "\nRecord counts:"
puts "  Commits:        #{counts[:commits]}"
puts "  BranchCommits:  #{counts[:branch_commits]}"
puts "  Changes:        #{counts[:changes]}"
puts "  Snapshots:      #{counts[:snapshots]}"

puts "\nPer-operation averages:"
puts "  commit_create:        #{(timings[:commit_create] / counts[:commits] * 1000).round(3)}ms"
puts "  branch_commit_create: #{(timings[:branch_commit_create] / counts[:branch_commits] * 1000).round(3)}ms"
if counts[:changes] > 0
  puts "  change_create:        #{(timings[:change_create] / counts[:changes] * 1000).round(3)}ms"
end
if counts[:snapshots] > 0
  puts "  snapshot_create:      #{(timings[:snapshot_create] / counts[:snapshots] * 1000).round(3)}ms"
end
