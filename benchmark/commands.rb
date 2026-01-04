#!/usr/bin/env ruby
# frozen_string_literal: true

require "benchmark"
require "optparse"

options = {
  iterations: 3,
  repo: nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: bin/benchmark commands [options]"

  opts.on("-r", "--repo=PATH", "Path to repository to benchmark against") do |v|
    options[:repo] = v
  end

  opts.on("-n", "--iterations=N", Integer, "Number of iterations per command (default: 3)") do |v|
    options[:iterations] = v
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

unless options[:repo]
  puts "Error: --repo is required"
  puts "Usage: bin/benchmark commands --repo /path/to/repo"
  exit 1
end

repo_path = File.expand_path(options[:repo])
unless File.directory?(repo_path)
  puts "Error: #{repo_path} is not a directory"
  exit 1
end

unless File.exist?(File.join(repo_path, ".git", "pkgs.sqlite3"))
  puts "Error: #{repo_path} does not have a git-pkgs database"
  puts "Run 'git pkgs init' in that repository first"
  exit 1
end

iterations = options[:iterations]
gem_root = File.expand_path("../..", __FILE__)

# Use bundle exec to ensure we run the local development version
commands = {
  "blame" => "bundle exec --gemfile=#{gem_root}/Gemfile ruby -I#{gem_root}/lib #{gem_root}/exe/git-pkgs blame --no-pager",
  "stale" => "bundle exec --gemfile=#{gem_root}/Gemfile ruby -I#{gem_root}/lib #{gem_root}/exe/git-pkgs stale --no-pager",
  "stats" => "bundle exec --gemfile=#{gem_root}/Gemfile ruby -I#{gem_root}/lib #{gem_root}/exe/git-pkgs stats --no-pager",
  "log" => "bundle exec --gemfile=#{gem_root}/Gemfile ruby -I#{gem_root}/lib #{gem_root}/exe/git-pkgs log --no-pager",
  "list" => "bundle exec --gemfile=#{gem_root}/Gemfile ruby -I#{gem_root}/lib #{gem_root}/exe/git-pkgs list --no-pager"
}

puts "Command benchmarks"
puts "=" * 60
puts "Repository: #{repo_path}"
puts "Iterations: #{iterations}"
puts

results = {}

Dir.chdir(repo_path) do
  commands.each do |name, cmd|
    times = []

    # Warmup run
    system(cmd, out: File::NULL, err: File::NULL)

    iterations.times do
      time = Benchmark.realtime do
        system(cmd, out: File::NULL, err: File::NULL)
      end
      times << time
    end

    avg = times.sum / times.size
    min = times.min
    max = times.max
    results[name] = { avg: avg, min: min, max: max }

    puts format("%-10s avg: %6.3fs  min: %6.3fs  max: %6.3fs", name, avg, min, max)
  end
end

puts
puts "Total average: #{format("%.3fs", results.values.sum { |r| r[:avg] })}"
