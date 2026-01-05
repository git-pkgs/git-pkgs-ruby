# frozen_string_literal: true

require "test_helper"

class Git::Pkgs::TestDatabase < Minitest::Test
  include TestHelpers

  def setup
    create_test_repo
    add_file("README.md", "# Test")
    commit("Initial commit")
    @git_dir = File.join(@test_dir, ".git")
  end

  def teardown
    cleanup_test_repo
  end

  def test_path_returns_database_path
    path = Git::Pkgs::Database.path(@git_dir)
    assert_equal File.join(@git_dir, "pkgs.sqlite3"), path
  end

  def test_exists_returns_false_when_no_database
    refute Git::Pkgs::Database.exists?(@git_dir)
  end

  def test_connect_and_create_schema_creates_database
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
    assert File.exist?(Git::Pkgs::Database.path(@git_dir))
  end

  def test_create_schema_creates_tables
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema

    db = Git::Pkgs::Database.db
    assert db.table_exists?(:branches)
    assert db.table_exists?(:commits)
    assert db.table_exists?(:branch_commits)
    assert db.table_exists?(:manifests)
    assert db.table_exists?(:dependency_changes)
    assert db.table_exists?(:dependency_snapshots)
  end

  def test_drop_removes_database
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
    assert Git::Pkgs::Database.exists?(@git_dir)

    Git::Pkgs::Database.drop(@git_dir)
    refute Git::Pkgs::Database.exists?(@git_dir)
  end
end
