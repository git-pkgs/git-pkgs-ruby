#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "git/pkgs"
require "benchmark"

repo_path = ARGV[0] || "/Users/andrew/code/octobox"
sample_size = (ARGV[1] || 500).to_i

# Setup in-memory database for fair comparison
Git::Pkgs::Database.connect_memory

repo = Git::Pkgs::Repository.new(repo_path)
analyzer = Git::Pkgs::Analyzer.new(repo)

walker = repo.walk(repo.default_branch)
commits = walker.take(sample_size)

puts "Full pipeline benchmark: #{commits.size} commits"
puts "=" * 60

timings = {
  git_diff: 0.0,
  filtering: 0.0,
  parsing: 0.0,
  db_writes: 0.0
}

snapshot = {}
branch = Git::Pkgs::Models::Branch.find_or_create("main")
position = 0

commits.each do |rugged_commit|
  next if repo.merge_commit?(rugged_commit)
  position += 1

  # Git diff extraction
  blob_paths = nil
  timings[:git_diff] += Benchmark.realtime do
    blob_paths = repo.blob_paths(rugged_commit)
  end

  all_paths = blob_paths.map { |p| p[:path] }

  # Filtering (regex + identify_manifests)
  result = nil
  timings[:filtering] += Benchmark.realtime do
    next unless analyzer.might_have_manifests?(all_paths)

    added_paths = blob_paths.select { |p| p[:status] == :added }.map { |p| p[:path] }
    modified_paths = blob_paths.select { |p| p[:status] == :modified }.map { |p| p[:path] }
    removed_paths = blob_paths.select { |p| p[:status] == :deleted }.map { |p| p[:path] }

    added_manifests = Bibliothecary.identify_manifests(added_paths)
    modified_manifests = Bibliothecary.identify_manifests(modified_paths)
    removed_manifests = Bibliothecary.identify_manifests(removed_paths)

    result = (added_manifests + modified_manifests + removed_manifests).any?
  end

  # Full analysis with parsing
  analysis_result = nil
  if result
    timings[:parsing] += Benchmark.realtime do
      analysis_result = analyzer.analyze_commit(rugged_commit, snapshot)
    end
  end

  # Database writes
  timings[:db_writes] += Benchmark.realtime do
    commit = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)
    Git::Pkgs::Models::BranchCommit.find_or_create_by(
      branch: branch,
      commit: commit,
      position: position
    )

    if analysis_result && analysis_result[:changes].any?
      commit.update(has_dependency_changes: true)

      analysis_result[:changes].each do |change|
        manifest = Git::Pkgs::Models::Manifest.find_or_create(
          path: change[:manifest_path],
          platform: change[:platform],
          kind: change[:kind]
        )

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

      snapshot = analysis_result[:snapshot]

      snapshot.each do |(manifest_path, name), dep_info|
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
    end
  end
end

total = timings.values.sum

puts "\nFull pipeline breakdown:"
puts "-" * 60
timings.each do |phase, time|
  pct = total > 0 ? (time / total * 100).round(1) : 0
  puts "  #{phase.to_s.ljust(15)} #{time.round(3).to_s.rjust(8)}s  (#{pct}%)"
end
puts "-" * 60
puts "  #{'Total'.ljust(15)} #{total.round(3).to_s.rjust(8)}s"

puts "\nThroughput: #{(position / total).round(1)} commits/sec"
puts "Cache stats: #{analyzer.cache_stats}"
