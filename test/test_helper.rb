# frozen_string_literal: true

unless ENV["DISABLE_SIMPLECOV"]
  require "simplecov"
  SimpleCov.start do
    add_filter "/test/"
    enable_coverage :branch
  end
end

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Suppress warnings from bibliothecary gem
Warning[:deprecated] = false
original_verbose = $VERBOSE
$VERBOSE = nil
require "git/pkgs"
$VERBOSE = original_verbose

require "minitest/autorun"

# Parallel test execution is opt-in per test class.
# Add `parallelize_me!` to test classes that:
# 1. Don't use Dir.chdir
# 2. Don't capture $stdout
# 3. Don't modify global singletons (Bibliothecary.configuration, etc.)

require "fileutils"
require "tmpdir"

module TestHelpers
  def create_test_repo
    @test_dir = Dir.mktmpdir("git-pkgs-test")
    git("init --initial-branch=main")
    git("config user.email 'test@example.com'")
    git("config user.name 'Test User'")
    git("config commit.gpgsign false")
    @test_dir
  end

  def cleanup_test_repo
    Git::Pkgs::Database.disconnect
    FileUtils.rm_rf(@test_dir) if @test_dir && File.exist?(@test_dir)
  end

  def add_file(path, content)
    full_path = File.join(@test_dir, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
    git("add #{path}")
  end

  def commit(message)
    git("commit -m '#{message}'")
  end

  def git(cmd)
    system("git -C #{@test_dir} #{cmd}", out: File::NULL, err: File::NULL)
  end

  def run_cli(*args)
    old_git_dir = Git::Pkgs.git_dir
    old_work_tree = Git::Pkgs.work_tree
    Git::Pkgs.git_dir = File.join(@test_dir, ".git")
    Git::Pkgs.work_tree = @test_dir
    capture_stdout { Git::Pkgs::CLI.run(args.flatten) }
  ensure
    Git::Pkgs.git_dir = old_git_dir
    Git::Pkgs.work_tree = old_work_tree
  end

  def sample_gemfile(gems = {})
    lines = ['source "https://rubygems.org"', ""]
    gems.each do |name, version|
      if version
        lines << "gem \"#{name}\", \"#{version}\""
      else
        lines << "gem \"#{name}\""
      end
    end
    lines.join("\n")
  end

  def sample_package_json(deps = {})
    JSON.generate({
      "name" => "test-package",
      "version" => "1.0.0",
      "dependencies" => deps
    })
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end

# Base test class for tests that use the database
class Git::Pkgs::DatabaseTest < Minitest::Test
  include TestHelpers

  def setup
    create_test_repo
    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end
end
