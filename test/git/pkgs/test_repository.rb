# frozen_string_literal: true

require "test_helper"

class Git::Pkgs::TestRepository < Minitest::Test
  include TestHelpers

  def setup
    create_test_repo
    add_file("README.md", "# Test")
    commit("Initial commit")
  end

  def teardown
    cleanup_test_repo
  end

  def test_initializes_with_path
    repo = Git::Pkgs::Repository.new(@test_dir)
    assert_equal @test_dir, repo.path
  end

  def test_finds_git_dir
    repo = Git::Pkgs::Repository.new(@test_dir)
    # Use realpath to handle symlinks (e.g., /var -> /private/var on macOS)
    expected = File.realpath(File.join(@test_dir, ".git"))
    actual = File.realpath(repo.git_dir)
    assert_equal expected, actual
  end

  def test_default_branch
    repo = Git::Pkgs::Repository.new(@test_dir)
    assert_equal "main", repo.default_branch
  end

  def test_branch_exists
    repo = Git::Pkgs::Repository.new(@test_dir)
    assert repo.branch_exists?("main")
    refute repo.branch_exists?("nonexistent")
  end

  def test_walk_returns_commits
    add_file("file1.txt", "content")
    commit("Second commit")

    repo = Git::Pkgs::Repository.new(@test_dir)
    commits = repo.walk("main").to_a

    assert_equal 2, commits.size
  end

  def test_blob_paths_for_initial_commit
    repo = Git::Pkgs::Repository.new(@test_dir)
    first_commit = repo.walk("main").first
    paths = repo.blob_paths(first_commit)

    assert_equal 1, paths.size
    assert_equal :added, paths.first[:status]
    assert_equal "README.md", paths.first[:path]
  end

  def test_content_at_commit
    repo = Git::Pkgs::Repository.new(@test_dir)
    first_commit = repo.walk("main").first
    content = repo.content_at_commit(first_commit, "README.md")

    assert_equal "# Test", content
  end

  def test_rev_parse_resolves_head
    repo = Git::Pkgs::Repository.new(@test_dir)
    sha = repo.rev_parse("HEAD")

    assert sha
    assert_equal 40, sha.length
    assert_equal repo.head_sha, sha
  end

  def test_rev_parse_resolves_relative_refs
    add_file("file1.txt", "content")
    commit("Second commit")

    repo = Git::Pkgs::Repository.new(@test_dir)
    head_sha = repo.rev_parse("HEAD")
    parent_sha = repo.rev_parse("HEAD~1")

    assert head_sha
    assert parent_sha
    refute_equal head_sha, parent_sha
  end

  def test_rev_parse_returns_nil_for_invalid_ref
    repo = Git::Pkgs::Repository.new(@test_dir)
    sha = repo.rev_parse("nonexistent-ref")

    assert_nil sha
  end
end
