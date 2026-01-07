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

  def test_create_schema_sets_version
    Git::Pkgs::Database.connect(@git_dir, check_version: false)
    Git::Pkgs::Database.create_schema

    assert_equal Git::Pkgs::Database::SCHEMA_VERSION, Git::Pkgs::Database.stored_version
  end

  def test_needs_upgrade_returns_true_for_old_schema
    Git::Pkgs::Database.connect(@git_dir, check_version: false)
    Git::Pkgs::Database.create_schema
    Git::Pkgs::Database.set_version(1)

    assert Git::Pkgs::Database.needs_upgrade?
  end

  def test_needs_upgrade_returns_false_for_current_schema
    Git::Pkgs::Database.connect(@git_dir, check_version: false)
    Git::Pkgs::Database.create_schema

    refute Git::Pkgs::Database.needs_upgrade?
  end

  def test_check_version_migrates_old_schema
    Git::Pkgs::Database.connect(@git_dir, check_version: false)
    Git::Pkgs::Database.create_schema
    Git::Pkgs::Database.set_version(1)

    assert Git::Pkgs::Database.needs_upgrade?
    Git::Pkgs::Database.check_version!
    refute Git::Pkgs::Database.needs_upgrade?
    assert_equal Git::Pkgs::Database::SCHEMA_VERSION, Git::Pkgs::Database.stored_version
  end

  def test_migrate_to_v2_adds_vuln_tables
    Git::Pkgs::Database.connect(@git_dir, check_version: false)

    # Create only v1 tables manually
    db = Git::Pkgs::Database.db
    db.create_table(:schema_info) { Integer :version }
    db.create_table(:branches) { primary_key :id; String :name }
    db.create_table(:commits) { primary_key :id; String :sha }
    db.create_table(:branch_commits) { primary_key :id }
    db.create_table(:manifests) { primary_key :id; String :path }
    db.create_table(:dependency_changes) { primary_key :id; String :name }
    db.create_table(:dependency_snapshots) { primary_key :id; String :name }
    Git::Pkgs::Database.set_version(1)

    refute db.table_exists?(:packages)
    refute db.table_exists?(:vulnerabilities)

    Git::Pkgs::Database.migrate!

    assert db.table_exists?(:packages)
    assert db.table_exists?(:vulnerabilities)
    assert db.table_exists?(:vulnerability_packages)
    assert_equal Git::Pkgs::Database::SCHEMA_VERSION, Git::Pkgs::Database.stored_version
  end

  def test_create_schema_creates_vuln_tables
    Git::Pkgs::Database.connect(@git_dir, check_version: false)
    Git::Pkgs::Database.create_schema

    db = Git::Pkgs::Database.db
    assert db.table_exists?(:packages)
    assert db.table_exists?(:vulnerabilities)
    assert db.table_exists?(:vulnerability_packages)
  end

  def test_connect_memory_creates_full_schema
    Git::Pkgs::Database.connect_memory

    db = Git::Pkgs::Database.db
    assert db.table_exists?(:commits)
    assert db.table_exists?(:packages)
    assert db.table_exists?(:vulnerabilities)
    assert db.table_exists?(:vulnerability_packages)
  end
end
