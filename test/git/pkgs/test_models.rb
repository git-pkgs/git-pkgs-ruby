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

  def test_dependency_change_purl_from_lockfile
    repo = Git::Pkgs::Repository.new(@test_dir)
    rugged_commit = repo.walk("main").first
    commit = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile.lock",
      ecosystem: "rubygems",
      kind: "lockfile"
    )

    change = Git::Pkgs::Models::DependencyChange.create(
      commit: commit,
      manifest: manifest,
      name: "rails",
      ecosystem: "rubygems",
      change_type: "added",
      requirement: "7.0.0"
    )

    assert_equal "pkg:gem/rails@7.0.0", change.purl.to_s
    assert_equal "pkg:gem/rails", change.purl(with_version: false).to_s
  end

  def test_dependency_change_purl_from_manifest_omits_version
    repo = Git::Pkgs::Repository.new(@test_dir)
    rugged_commit = repo.walk("main").first
    commit = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    change = Git::Pkgs::Models::DependencyChange.create(
      commit: commit,
      manifest: manifest,
      name: "rails",
      ecosystem: "rubygems",
      change_type: "added",
      requirement: "~> 7.0"
    )

    assert_equal "pkg:gem/rails", change.purl.to_s
  end

  def test_dependency_snapshot_purl_from_lockfile
    repo = Git::Pkgs::Repository.new(@test_dir)
    rugged_commit = repo.walk("main").first
    commit = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "package-lock.json",
      ecosystem: "npm",
      kind: "lockfile"
    )

    snapshot = Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit,
      manifest: manifest,
      name: "lodash",
      ecosystem: "npm",
      requirement: "4.17.21"
    )

    assert_equal "pkg:npm/lodash@4.17.21", snapshot.purl.to_s
    assert_equal "pkg:npm/lodash", snapshot.purl(with_version: false).to_s
  end

  def test_package_creation
    package = Git::Pkgs::Models::Package.create(
      purl: "pkg:gem/rails",
      ecosystem: "rubygems",
      name: "rails",
      latest_version: "7.1.0",
      license: "MIT",
      description: "Full-stack web framework",
      source: "ecosystems"
    )

    assert_equal "pkg:gem/rails", package.purl
    assert_equal "7.1.0", package.latest_version
    assert_equal "MIT", package.license
    assert_equal "ecosystems", package.source
  end

  def test_package_parsed_purl
    package = Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")

    assert_equal "gem", package.parsed_purl.type
    assert_equal "rails", package.parsed_purl.name
  end

  def test_package_enriched
    package = Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")
    refute package.enriched?

    package.update(enriched_at: Time.now)
    assert package.enriched?
  end

  def test_version_creation
    Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")

    version = Git::Pkgs::Models::Version.create(
      purl: "pkg:gem/rails@7.0.0",
      package_purl: "pkg:gem/rails",
      license: "MIT",
      published_at: Time.parse("2021-12-15"),
      integrity: "sha256:abc123",
      source: "ecosystems"
    )

    assert_equal "pkg:gem/rails@7.0.0", version.purl
    assert_equal "pkg:gem/rails", version.package_purl
    assert_equal "7.0.0", version.version_string
  end

  def test_version_belongs_to_package
    package = Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")

    version = Git::Pkgs::Models::Version.create(
      purl: "pkg:gem/rails@7.0.0",
      package_purl: "pkg:gem/rails"
    )

    assert_equal package.id, version.package.id
    assert_includes package.versions.map(&:id), version.id
  end

  def test_package_purl_uniqueness
    Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")

    assert_raises(Sequel::UniqueConstraintViolation) do
      Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")
    end
  end

  def test_version_purl_uniqueness
    Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")
    Git::Pkgs::Models::Version.create(purl: "pkg:gem/rails@7.0.0", package_purl: "pkg:gem/rails")

    assert_raises(Sequel::UniqueConstraintViolation) do
      Git::Pkgs::Models::Version.create(purl: "pkg:gem/rails@7.0.0", package_purl: "pkg:gem/rails")
    end
  end

  def test_version_latest_as_of
    Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")

    Git::Pkgs::Models::Version.create(
      purl: "pkg:gem/rails@6.1.0",
      package_purl: "pkg:gem/rails",
      published_at: Time.parse("2020-12-09")
    )
    Git::Pkgs::Models::Version.create(
      purl: "pkg:gem/rails@7.0.0",
      package_purl: "pkg:gem/rails",
      published_at: Time.parse("2021-12-15")
    )
    Git::Pkgs::Models::Version.create(
      purl: "pkg:gem/rails@7.1.0",
      package_purl: "pkg:gem/rails",
      published_at: Time.parse("2023-10-05")
    )

    # Before any releases
    result = Git::Pkgs::Models::Version.latest_as_of(
      package_purl: "pkg:gem/rails",
      date: Time.parse("2020-01-01")
    )
    assert_nil result

    # After 6.1.0 but before 7.0.0
    result = Git::Pkgs::Models::Version.latest_as_of(
      package_purl: "pkg:gem/rails",
      date: Time.parse("2021-06-01")
    )
    assert_equal "6.1.0", result.version_string

    # After 7.0.0 but before 7.1.0
    result = Git::Pkgs::Models::Version.latest_as_of(
      package_purl: "pkg:gem/rails",
      date: Time.parse("2022-06-01")
    )
    assert_equal "7.0.0", result.version_string

    # After all releases
    result = Git::Pkgs::Models::Version.latest_as_of(
      package_purl: "pkg:gem/rails",
      date: Time.parse("2024-01-01")
    )
    assert_equal "7.1.0", result.version_string
  end

  def test_version_latest_as_of_ignores_versions_without_published_at
    Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")

    Git::Pkgs::Models::Version.create(
      purl: "pkg:gem/rails@6.1.0",
      package_purl: "pkg:gem/rails",
      published_at: Time.parse("2020-12-09")
    )
    Git::Pkgs::Models::Version.create(
      purl: "pkg:gem/rails@7.0.0",
      package_purl: "pkg:gem/rails",
      published_at: nil
    )

    result = Git::Pkgs::Models::Version.latest_as_of(
      package_purl: "pkg:gem/rails",
      date: Time.parse("2024-01-01")
    )
    assert_equal "6.1.0", result.version_string
  end

  def test_version_latest_as_of_compares_semantically
    Git::Pkgs::Models::Package.create(purl: "pkg:npm/lodash", ecosystem: "npm", name: "lodash")

    # Published out of semantic order
    Git::Pkgs::Models::Version.create(
      purl: "pkg:npm/lodash@4.17.21",
      package_purl: "pkg:npm/lodash",
      published_at: Time.parse("2021-02-20")
    )
    Git::Pkgs::Models::Version.create(
      purl: "pkg:npm/lodash@4.17.19",
      package_purl: "pkg:npm/lodash",
      published_at: Time.parse("2020-07-15")
    )
    Git::Pkgs::Models::Version.create(
      purl: "pkg:npm/lodash@4.17.15",
      package_purl: "pkg:npm/lodash",
      published_at: Time.parse("2019-07-19")
    )

    # Should return highest version, not most recent
    result = Git::Pkgs::Models::Version.latest_as_of(
      package_purl: "pkg:npm/lodash",
      date: Time.parse("2022-01-01")
    )
    assert_equal "4.17.21", result.version_string
  end
end
