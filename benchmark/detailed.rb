#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "git/pkgs"
require "benchmark"

repo_path = ARGV[0] || "/Users/andrew/code/octobox"
sample_size = (ARGV[1] || 500).to_i

repo = Git::Pkgs::Repository.new(repo_path)
analyzer = Git::Pkgs::Analyzer.new(repo)

walker = repo.walk(repo.default_branch)
commits = walker.take(sample_size)

puts "Benchmarking #{commits.size} commits from #{repo_path}"
puts "=" * 60

timings = {
  walk_iteration: 0.0,
  blob_paths: 0.0,
  regex_check: 0.0,
  identify_manifests: 0.0,
  parse_manifests: 0.0,
  db_operations: 0.0
}

counts = {
  total: 0,
  merge_commits: 0,
  regex_passed: 0,
  identify_passed: 0,
  has_changes: 0,
  paths_by_commit: []
}

platform_times = Hash.new(0.0)
platform_counts = Hash.new(0)

commits.each do |rugged_commit|
  counts[:total] += 1

  if repo.merge_commit?(rugged_commit)
    counts[:merge_commits] += 1
    next
  end

  # Phase 1: Extract diff/file paths
  blob_paths = nil
  timings[:blob_paths] += Benchmark.realtime do
    blob_paths = repo.blob_paths(rugged_commit)
  end

  all_paths = blob_paths.map { |p| p[:path] }
  counts[:paths_by_commit] << all_paths.size

  # Phase 2: Quick regex check
  regex_match = nil
  timings[:regex_check] += Benchmark.realtime do
    regex_match = analyzer.might_have_manifests?(all_paths)
  end

  next unless regex_match
  counts[:regex_passed] += 1

  # Phase 3: Bibliothecary identify_manifests
  added_paths = blob_paths.select { |p| p[:status] == :added }.map { |p| p[:path] }
  modified_paths = blob_paths.select { |p| p[:status] == :modified }.map { |p| p[:path] }
  removed_paths = blob_paths.select { |p| p[:status] == :deleted }.map { |p| p[:path] }

  added_manifests = modified_manifests = removed_manifests = nil
  timings[:identify_manifests] += Benchmark.realtime do
    added_manifests = Bibliothecary.identify_manifests(added_paths)
    modified_manifests = Bibliothecary.identify_manifests(modified_paths)
    removed_manifests = Bibliothecary.identify_manifests(removed_paths)
  end

  all_manifests = added_manifests + modified_manifests + removed_manifests
  next if all_manifests.empty?
  counts[:identify_passed] += 1

  # Phase 4: Parse manifests (with platform tracking)
  timings[:parse_manifests] += Benchmark.realtime do
    all_manifests.each do |manifest_path|
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      blob_oid = repo.blob_oid_at_commit(rugged_commit, manifest_path)
      if blob_oid
        content = repo.blob_content(blob_oid)
        if content
          result = Bibliothecary.analyse_file(manifest_path, content).first
          if result
            platform_counts[result[:platform]] += 1
            platform_times[result[:platform]] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          end
        end
      end
    end
  end

  counts[:has_changes] += 1
end

total_time = timings.values.sum

puts "\nTiming breakdown:"
puts "-" * 60
timings.each do |phase, time|
  pct = (time / total_time * 100).round(1)
  puts "  #{phase.to_s.ljust(20)} #{time.round(3).to_s.rjust(8)}s  (#{pct}%)"
end
puts "-" * 60
puts "  #{'Total'.ljust(20)} #{total_time.round(3).to_s.rjust(8)}s"

puts "\nCommit counts:"
puts "-" * 60
puts "  Total commits:       #{counts[:total]}"
puts "  Merge commits:       #{counts[:merge_commits]} (skipped)"
puts "  Regex passed:        #{counts[:regex_passed]} (#{(counts[:regex_passed].to_f / (counts[:total] - counts[:merge_commits]) * 100).round(1)}%)"
puts "  Identify passed:     #{counts[:identify_passed]}"
puts "  Has actual changes:  #{counts[:has_changes]}"

if counts[:paths_by_commit].any?
  avg_paths = counts[:paths_by_commit].sum.to_f / counts[:paths_by_commit].size
  max_paths = counts[:paths_by_commit].max
  puts "\nPaths per commit:"
  puts "  Average: #{avg_paths.round(1)}"
  puts "  Max: #{max_paths}"
end

if platform_times.any?
  puts "\nTime by platform:"
  puts "-" * 60
  platform_times.sort_by { |_, v| -v }.each do |platform, time|
    count = platform_counts[platform]
    avg = (time / count * 1000).round(2)
    puts "  #{platform.ljust(20)} #{time.round(3).to_s.rjust(8)}s  (#{count} files, #{avg}ms avg)"
  end
end

puts "\nPer-commit averages:"
non_merge = counts[:total] - counts[:merge_commits]
puts "  blob_paths:          #{(timings[:blob_paths] / non_merge * 1000).round(3)}ms"
puts "  regex_check:         #{(timings[:regex_check] / non_merge * 1000).round(3)}ms"
if counts[:regex_passed] > 0
  puts "  identify_manifests:  #{(timings[:identify_manifests] / counts[:regex_passed] * 1000).round(3)}ms (when regex passes)"
end

commits_per_sec = counts[:total] / total_time
puts "\nThroughput: #{commits_per_sec.round(1)} commits/sec"
