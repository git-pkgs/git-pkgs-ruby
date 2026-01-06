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
require "fileutils"
require "tmpdir"

module TestHelpers
  def create_test_repo
    @test_dir = Dir.mktmpdir("git-pkgs-test")
    Dir.chdir(@test_dir) do
      system("git init --initial-branch=main", out: File::NULL, err: File::NULL)
      system("git config user.email 'test@example.com'", out: File::NULL)
      system("git config user.name 'Test User'", out: File::NULL)
    end
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
    Dir.chdir(@test_dir) do
      system("git add #{path}", out: File::NULL, err: File::NULL)
    end
  end

  def commit(message)
    Dir.chdir(@test_dir) do
      system("git commit -m '#{message}'", out: File::NULL, err: File::NULL)
    end
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
