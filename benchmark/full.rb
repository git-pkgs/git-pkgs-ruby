#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmarks the full init pipeline by calling the actual Init command.
# For detailed phase breakdowns, use detailed.rb instead.

require "bundler/setup"
require "git/pkgs"
require "benchmark"

repo_path = ARGV[0] || "/Users/andrew/code/octobox"

Git::Pkgs.quiet = true

# Clean slate
db_path = File.join(repo_path, ".git", "pkgs.sqlite3")
File.delete(db_path) if File.exist?(db_path)

time = Benchmark.realtime do
  Git::Pkgs::CLI.run(["--git-dir=#{File.join(repo_path, '.git')}", "init", "--force", "--no-hooks"])
end

# Get stats
Git::Pkgs::Database.connect(File.join(repo_path, ".git"))
commits = Git::Pkgs::Models::Commit.count
changes = Git::Pkgs::Models::DependencyChange.count
snapshots = Git::Pkgs::Models::DependencySnapshot.count

puts "Full init benchmark"
puts "=" * 60
puts "Repository: #{repo_path}"
puts "Time: #{time.round(2)}s"
puts "Commits: #{commits}"
puts "Dependency changes: #{changes}"
puts "Snapshots: #{snapshots}"
puts "Throughput: #{(commits / time).round(1)} commits/sec"

# Cleanup
File.delete(db_path) if File.exist?(db_path)
