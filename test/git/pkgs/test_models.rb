# frozen_string_literal: true

require "test_helper"

class Git::Pkgs::TestModels < Minitest::Test
  include TestHelpers

  def setup
    create_test_repo
    add_file("README.md", "# Test")
    commit("Initial commit")

    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def test_branch_find_or_create
    branch = Git::Pkgs::Models::Branch.find_or_create("main")
    assert_equal "main", branch.name

    same_branch = Git::Pkgs::Models::Branch.find_or_create("main")
    assert_equal branch.id, same_branch.id
  end

  def test_commit_find_or_create_from_rugged
    repo = Git::Pkgs::Repository.new(@test_dir)
    rugged_commit = repo.walk("main").first

    commit = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)

    assert_equal rugged_commit.oid, commit.sha
    assert_equal "Test User", commit.author_name
    assert_equal "test@example.com", commit.author_email
    assert_includes commit.message, "Initial commit"
  end

  def test_commit_short_sha
    repo = Git::Pkgs::Repository.new(@test_dir)
    rugged_commit = repo.walk("main").first
    commit = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)

    assert_equal 7, commit.short_sha.length
    assert commit.sha.start_with?(commit.short_sha)
  end

  def test_manifest_find_or_create
    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    assert_equal "Gemfile", manifest.path
    assert_equal "rubygems", manifest.ecosystem
    assert_equal "manifest", manifest.kind
  end

  def test_dependency_change_scopes
    repo = Git::Pkgs::Repository.new(@test_dir)
    rugged_commit = repo.walk("main").first
    commit = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    Git::Pkgs::Models::DependencyChange.create(
      commit: commit,
      manifest: manifest,
      name: "rails",
      ecosystem: "rubygems",
      change_type: "added",
      requirement: "~> 7.0"
    )

    Git::Pkgs::Models::DependencyChange.create(
      commit: commit,
      manifest: manifest,
      name: "puma",
      ecosystem: "rubygems",
      change_type: "removed",
      requirement: "~> 5.0"
    )

    assert_equal 1, Git::Pkgs::Models::DependencyChange.added.count
    assert_equal 1, Git::Pkgs::Models::DependencyChange.removed.count
    assert_equal 1, Git::Pkgs::Models::DependencyChange.for_package("rails").count
    assert_equal 2, Git::Pkgs::Models::DependencyChange.for_platform("rubygems").count
  end

  def test_branch_commit_associations
    repo = Git::Pkgs::Repository.new(@test_dir)
    rugged_commit = repo.walk("main").first

    branch = Git::Pkgs::Models::Branch.find_or_create("main")
    commit = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)

    Git::Pkgs::Models::BranchCommit.create(
      branch: branch,
      commit: commit,
      position: 1
    )

    assert_includes branch.commits, commit
    assert_includes commit.branches, branch
  end
end
