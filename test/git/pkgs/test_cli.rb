# frozen_string_literal: true

require "test_helper"
require "stringio"
require "securerandom"

class Git::Pkgs::TestCLI < Minitest::Test
  include TestHelpers

  def test_help_command
    output = capture_stdout do
      Git::Pkgs::CLI.run(["help"])
    end

    assert_includes output, "Usage: git pkgs"
    assert_includes output, "init"
    assert_includes output, "list"
    assert_includes output, "history"
  end

  def test_version_command
    output = capture_stdout do
      Git::Pkgs::CLI.run(["--version"])
    end

    assert_includes output, Git::Pkgs::VERSION
  end

  def test_unknown_command_exits_with_error
    assert_raises(SystemExit) do
      capture_stderr do
        Git::Pkgs::CLI.run(["unknown"])
      end
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end

class Git::Pkgs::TestDiffCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    commit("Initial commit")
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'\ngem 'puma'")
    commit("Add puma")
    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def test_parse_range_argument_with_dotdot
    cmd = Git::Pkgs::Commands::Diff.new(["main..feature"])
    from_ref, to_ref = cmd.send(:parse_range_argument)
    assert_equal "main", from_ref
    assert_equal "feature", to_ref
  end

  def test_parse_range_argument_with_trailing_dotdot
    cmd = Git::Pkgs::Commands::Diff.new(["main.."])
    from_ref, to_ref = cmd.send(:parse_range_argument)
    assert_equal "main", from_ref
    assert_equal "HEAD", to_ref
  end

  def test_parse_range_argument_with_single_ref
    cmd = Git::Pkgs::Commands::Diff.new(["HEAD~10"])
    from_ref, to_ref = cmd.send(:parse_range_argument)
    assert_equal "HEAD~10", from_ref
    assert_equal "HEAD", to_ref
  end

  def test_parse_range_argument_with_no_args
    cmd = Git::Pkgs::Commands::Diff.new([])
    from_ref, to_ref = cmd.send(:parse_range_argument)
    assert_nil from_ref
    assert_nil to_ref
  end

  def test_parse_range_argument_ignores_flags
    cmd = Git::Pkgs::Commands::Diff.new(["--ecosystem=npm"])
    from_ref, to_ref = cmd.send(:parse_range_argument)
    assert_nil from_ref
    assert_nil to_ref
  end

  def test_find_or_create_from_repo_finds_existing_commit
    repo = Git::Pkgs::Repository.new(@test_dir)
    sha = repo.head_sha

    # Create commit in database first
    Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: "Test",
      author_name: "Test",
      author_email: "test@example.com",
      committed_at: Time.now
    )

    result = Git::Pkgs::Models::Commit.find_or_create_from_repo(repo, sha)

    assert result
    assert_equal sha, result.sha
  end

  def test_find_or_create_from_repo_creates_missing_commit
    repo = Git::Pkgs::Repository.new(@test_dir)
    sha = repo.head_sha

    # Commit doesn't exist in database yet
    assert_nil Git::Pkgs::Models::Commit.first(sha: sha)

    result = Git::Pkgs::Models::Commit.find_or_create_from_repo(repo, sha)

    assert result
    assert_equal sha, result.sha
    # Verify it was persisted
    assert Git::Pkgs::Models::Commit.first(sha: sha)
  end

  def test_find_or_create_from_repo_returns_nil_for_invalid_sha
    repo = Git::Pkgs::Repository.new(@test_dir)

    result = Git::Pkgs::Models::Commit.find_or_create_from_repo(repo, "0000000000000000000000000000000000000000")

    assert_nil result
  end

  def test_diff_shows_added_modified_removed
    repo = Git::Pkgs::Repository.new(@test_dir)
    head_sha = repo.head_sha
    parent_sha = repo.rev_parse("HEAD~1")

    # Create commits in database
    Git::Pkgs::Models::Commit.create(
      sha: parent_sha, message: "Initial",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now - 3600
    )
    head_commit = Git::Pkgs::Models::Commit.create(
      sha: head_sha, message: "Add puma",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")

    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "puma",
      change_type: "added", ecosystem: "rubygems", requirement: "~> 5.0"
    )
    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "rails",
      change_type: "modified", ecosystem: "rubygems", requirement: "~> 7.1",
      previous_requirement: "~> 7.0"
    )
    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "sidekiq",
      change_type: "removed", ecosystem: "rubygems", requirement: "~> 6.0"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Diff.new(["#{parent_sha}..#{head_sha}"]).run
      end
    end

    assert_includes output, "Added:"
    assert_includes output, "puma"
    assert_includes output, "Modified:"
    assert_includes output, "rails"
    assert_includes output, "Removed:"
    assert_includes output, "sidekiq"
    assert_includes output, "Summary:"
  end

  def test_diff_no_changes
    repo = Git::Pkgs::Repository.new(@test_dir)
    head_sha = repo.head_sha
    parent_sha = repo.rev_parse("HEAD~1")

    # Create commits without any dependency changes
    Git::Pkgs::Models::Commit.create(
      sha: parent_sha, message: "Initial",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now - 3600
    )
    Git::Pkgs::Models::Commit.create(
      sha: head_sha, message: "Add puma",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Diff.new(["#{parent_sha}..#{head_sha}"]).run
      end
    end

    assert_includes output, "No dependency changes"
  end

  def test_diff_filters_by_ecosystem
    repo = Git::Pkgs::Repository.new(@test_dir)
    head_sha = repo.head_sha
    parent_sha = repo.rev_parse("HEAD~1")

    Git::Pkgs::Models::Commit.create(
      sha: parent_sha, message: "Initial",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now - 3600
    )
    head_commit = Git::Pkgs::Models::Commit.create(
      sha: head_sha, message: "Add deps",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")
    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "rails",
      change_type: "added", ecosystem: "rubygems", requirement: "~> 7.0"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Diff.new(["#{parent_sha}..#{head_sha}", "--ecosystem=npm"]).run
      end
    end

    assert_includes output, "No dependency changes"
  end

  def test_diff_with_from_to_options
    repo = Git::Pkgs::Repository.new(@test_dir)
    head_sha = repo.head_sha
    parent_sha = repo.rev_parse("HEAD~1")

    Git::Pkgs::Models::Commit.create(
      sha: parent_sha, message: "Initial",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now - 3600
    )
    head_commit = Git::Pkgs::Models::Commit.create(
      sha: head_sha, message: "Add puma",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")
    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "puma",
      change_type: "added", ecosystem: "rubygems", requirement: "~> 5.0"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Diff.new(["--from=#{parent_sha}", "--to=#{head_sha}"]).run
      end
    end

    assert_includes output, "puma"
    assert_includes output, "Added:"
  end

  def test_diff_json_format
    repo = Git::Pkgs::Repository.new(@test_dir)
    head_sha = repo.head_sha
    parent_sha = repo.rev_parse("HEAD~1")

    Git::Pkgs::Models::Commit.create(
      sha: parent_sha, message: "Initial",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now - 3600
    )
    head_commit = Git::Pkgs::Models::Commit.create(
      sha: head_sha, message: "Add puma",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")
    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "puma",
      change_type: "added", ecosystem: "rubygems", requirement: "~> 5.0"
    )
    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "rails",
      change_type: "modified", ecosystem: "rubygems", requirement: "~> 7.1",
      previous_requirement: "~> 7.0"
    )
    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "sidekiq",
      change_type: "removed", ecosystem: "rubygems", requirement: "~> 6.0"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Diff.new(["#{parent_sha}..#{head_sha}", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data["added"].length
    assert_equal "puma", data["added"].first["name"]
    assert_equal 1, data["modified"].length
    assert_equal "rails", data["modified"].first["name"]
    assert_equal "~> 7.0", data["modified"].first["previous_requirement"]
    assert_equal "~> 7.1", data["modified"].first["requirement"]
    assert_equal 1, data["removed"].length
    assert_equal "sidekiq", data["removed"].first["name"]
    assert_equal 1, data["summary"]["added"]
    assert_equal 1, data["summary"]["modified"]
    assert_equal 1, data["summary"]["removed"]
  end

  def test_diff_json_format_no_changes
    repo = Git::Pkgs::Repository.new(@test_dir)
    head_sha = repo.head_sha
    parent_sha = repo.rev_parse("HEAD~1")

    Git::Pkgs::Models::Commit.create(
      sha: parent_sha, message: "Initial",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now - 3600
    )
    Git::Pkgs::Models::Commit.create(
      sha: head_sha, message: "No dep changes",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Diff.new(["#{parent_sha}..#{head_sha}", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal [], data["added"]
    assert_equal [], data["modified"]
    assert_equal [], data["removed"]
  end

  def test_diff_error_no_from_ref
    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Diff.new([]).run
        end
      end
    end

    assert_includes output, "Usage:"
  end

  def test_diff_error_invalid_from_ref
    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Diff.new(["nonexistent..HEAD"]).run
        end
      end
    end

    assert_includes output, "Could not resolve"
  end

  def test_diff_error_invalid_to_ref
    repo = Git::Pkgs::Repository.new(@test_dir)
    parent_sha = repo.rev_parse("HEAD~1")

    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Diff.new(["#{parent_sha}..nonexistent"]).run
        end
      end
    end

    assert_includes output, "Could not resolve"
  end

  def test_diff_with_only_added_changes
    repo = Git::Pkgs::Repository.new(@test_dir)
    head_sha = repo.head_sha
    parent_sha = repo.rev_parse("HEAD~1")

    Git::Pkgs::Models::Commit.create(
      sha: parent_sha, message: "Initial",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now - 3600
    )
    head_commit = Git::Pkgs::Models::Commit.create(
      sha: head_sha, message: "Add deps",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")
    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "rails",
      change_type: "added", ecosystem: "rubygems", requirement: "~> 7.0"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Diff.new(["#{parent_sha}..#{head_sha}"]).run
      end
    end

    assert_includes output, "Added:"
    assert_includes output, "rails"
    refute_includes output, "Modified:"
    refute_includes output, "Removed:"
  end

  def test_diff_with_only_removed_changes
    repo = Git::Pkgs::Repository.new(@test_dir)
    head_sha = repo.head_sha
    parent_sha = repo.rev_parse("HEAD~1")

    Git::Pkgs::Models::Commit.create(
      sha: parent_sha, message: "Initial",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now - 3600
    )
    head_commit = Git::Pkgs::Models::Commit.create(
      sha: head_sha, message: "Remove deps",
      author_name: "Test", author_email: "test@example.com",
      committed_at: Time.now
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")
    Git::Pkgs::Models::DependencyChange.create(
      commit: head_commit, manifest: manifest, name: "sidekiq",
      change_type: "removed", ecosystem: "rubygems", requirement: "~> 6.0"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Diff.new(["#{parent_sha}..#{head_sha}"]).run
      end
    end

    assert_includes output, "Removed:"
    assert_includes output, "sidekiq"
    refute_includes output, "Added:"
    refute_includes output, "Modified:"
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end

class Git::Pkgs::TestShowCommand < Git::Pkgs::DatabaseTest
  def setup
    super
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    commit("Add rails")
    @first_sha = get_head_sha
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'\ngem 'puma'")
    commit("Add puma")
    @second_sha = get_head_sha
  end

  def test_show_displays_changes_for_commit
    create_commit_with_changes(@second_sha, [
      { name: "puma", change_type: "added", requirement: ">= 0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Show.new([@second_sha]).run
      end
    end

    assert_includes output, "puma"
    assert_includes output, "Added:"
  end

  def test_show_defaults_to_head
    create_commit_with_changes(@second_sha, [
      { name: "puma", change_type: "added", requirement: ">= 0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Show.new([]).run
      end
    end

    assert_includes output, "puma"
  end

  def test_show_no_changes_message
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Show.new([@first_sha]).run
      end
    end

    assert_includes output, "No dependency changes"
  end

  def test_show_json_format
    create_commit_with_changes(@second_sha, [
      { name: "puma", change_type: "added", requirement: ">= 0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Show.new(["--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data["changes"].length
    assert_equal "puma", data["changes"].first["name"]
  end

  def test_show_filters_by_ecosystem
    create_commit_with_changes(@second_sha, [
      { name: "puma", change_type: "added", requirement: ">= 0", ecosystem: "rubygems" },
      { name: "express", change_type: "added", requirement: "^4.0", ecosystem: "npm" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Show.new(["--ecosystem=rubygems"]).run
      end
    end

    assert_includes output, "puma"
    refute_includes output, "express"
  end

  def get_head_sha
    Dir.chdir(@test_dir) do
      `git rev-parse HEAD`.strip
    end
  end

  def create_commit_with_changes(sha, changes)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: "Test commit",
      author_name: "Test User",
      author_email: "test@example.com",
      committed_at: Time.now,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create(
        commit: commit,
        manifest: manifest,
        name: change[:name],
        change_type: change[:change_type],
        requirement: change[:requirement],
        ecosystem: change[:ecosystem] || "rubygems",
        dependency_type: "runtime"
      )
    end

    commit
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

class Git::Pkgs::TestHistoryCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    commit("Add rails")
    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def test_history_filters_by_author
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added", requirement: ">= 0" }
    ])
    create_commit_with_author("bob", "bob@example.com", [
      { name: "puma", change_type: "added", requirement: ">= 0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::History.new(["--author=alice"]).run
      end
    end

    assert_includes output, "rails"
    refute_includes output, "puma"
  end

  def test_history_filters_by_author_email
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added", requirement: ">= 0" }
    ])
    create_commit_with_author("bob", "bob@example.com", [
      { name: "puma", change_type: "added", requirement: ">= 0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::History.new(["--author=bob@example"]).run
      end
    end

    refute_includes output, "rails"
    assert_includes output, "puma"
  end

  def test_history_filters_by_since
    create_commit_at(Time.new(2024, 1, 1), [
      { name: "rails", change_type: "added", requirement: ">= 0" }
    ])
    create_commit_at(Time.new(2024, 6, 1), [
      { name: "puma", change_type: "added", requirement: ">= 0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::History.new(["--since=2024-03-01"]).run
      end
    end

    refute_includes output, "rails"
    assert_includes output, "puma"
  end

  def test_history_filters_by_until
    create_commit_at(Time.new(2024, 1, 1), [
      { name: "rails", change_type: "added", requirement: ">= 0" }
    ])
    create_commit_at(Time.new(2024, 6, 1), [
      { name: "puma", change_type: "added", requirement: ">= 0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::History.new(["--until=2024-03-01"]).run
      end
    end

    assert_includes output, "rails"
    refute_includes output, "puma"
  end

  def test_history_filters_by_date_range
    create_commit_at(Time.new(2024, 1, 1), [
      { name: "rails", change_type: "added", requirement: ">= 0" }
    ])
    create_commit_at(Time.new(2024, 6, 1), [
      { name: "puma", change_type: "added", requirement: ">= 0" }
    ])
    create_commit_at(Time.new(2024, 12, 1), [
      { name: "sidekiq", change_type: "added", requirement: ">= 0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::History.new(["--since=2024-03-01", "--until=2024-09-01"]).run
      end
    end

    refute_includes output, "rails"
    assert_includes output, "puma"
    refute_includes output, "sidekiq"
  end

  def create_commit_with_author(name, email, changes)
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: "Test commit",
      author_name: name,
      author_email: email,
      committed_at: Time.now,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create(
        commit: commit,
        manifest: manifest,
        name: change[:name],
        change_type: change[:change_type],
        requirement: change[:requirement],
        ecosystem: "rubygems",
        dependency_type: "runtime"
      )
    end

    commit
  end

  def create_commit_at(time, changes)
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: "Test commit",
      author_name: "Test User",
      author_email: "test@example.com",
      committed_at: time,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create(
        commit: commit,
        manifest: manifest,
        name: change[:name],
        change_type: change[:change_type],
        requirement: change[:requirement],
        ecosystem: "rubygems",
        dependency_type: "runtime"
      )
    end

    commit
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

class Git::Pkgs::TestStatsCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    commit("Add rails")
    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def test_stats_with_since_filter
    old_time = Time.now - (30 * 24 * 60 * 60)
    recent_time = Time.now - (5 * 24 * 60 * 60)

    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ], committed_at: old_time)
    create_commit_with_author("bob", "bob@example.com", [
      { name: "puma", change_type: "added" }
    ], committed_at: recent_time)

    since_date = (Time.now - (10 * 24 * 60 * 60)).strftime("%Y-%m-%d")
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--since=#{since_date}"]).run
      end
    end

    assert_includes output, "Since: #{since_date}"
    assert_includes output, "puma"
  end

  def test_stats_with_until_filter
    old_time = Time.now - (30 * 24 * 60 * 60)
    recent_time = Time.now - (5 * 24 * 60 * 60)

    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ], committed_at: old_time)
    create_commit_with_author("bob", "bob@example.com", [
      { name: "puma", change_type: "added" }
    ], committed_at: recent_time)

    until_date = (Time.now - (10 * 24 * 60 * 60)).strftime("%Y-%m-%d")
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--until=#{until_date}"]).run
      end
    end

    assert_includes output, "Until: #{until_date}"
  end

  def test_stats_without_current_dependencies
    # No branch/snapshot setup, just changes
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new([]).run
      end
    end

    assert_includes output, "Dependency Statistics"
    assert_includes output, "Most Changed Dependencies"
  end

  def test_stats_by_author_shows_counts
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" },
      { name: "puma", change_type: "added" }
    ])
    create_commit_with_author("bob", "bob@example.com", [
      { name: "sidekiq", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--by-author"]).run
      end
    end

    assert_includes output, "alice"
    assert_includes output, "bob"
    assert_includes output, "2"  # alice's count
  end

  def test_stats_by_author_only_counts_added
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" },
      { name: "puma", change_type: "modified" },
      { name: "sidekiq", change_type: "removed" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--by-author"]).run
      end
    end

    assert_includes output, "alice"
    assert_includes output, "1"  # only the added one
  end

  def test_stats_by_author_json_format
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--by-author", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data.length
    assert_equal "alice", data.first["author"]
    assert_equal 1, data.first["added"]
  end

  def test_stats_by_author_respects_limit
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ])
    create_commit_with_author("bob", "bob@example.com", [
      { name: "puma", change_type: "added" }
    ])
    create_commit_with_author("charlie", "charlie@example.com", [
      { name: "sidekiq", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--by-author", "-n", "2"]).run
      end
    end

    lines = output.lines.select { |l| l.match?(/^\s+\d+\s+\w/) }
    assert_equal 2, lines.length
  end

  def test_stats_by_author_respects_since_filter
    old_time = Time.now - (30 * 24 * 60 * 60)  # 30 days ago
    recent_time = Time.now - (5 * 24 * 60 * 60)  # 5 days ago

    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ], committed_at: old_time)
    create_commit_with_author("bob", "bob@example.com", [
      { name: "puma", change_type: "added" }
    ], committed_at: recent_time)

    since_date = (Time.now - (10 * 24 * 60 * 60)).strftime("%Y-%m-%d")  # 10 days ago
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--by-author", "--since=#{since_date}"]).run
      end
    end

    assert_includes output, "bob"
    refute_includes output, "alice"
  end

  def test_stats_by_author_respects_until_filter
    old_time = Time.now - (30 * 24 * 60 * 60)  # 30 days ago
    recent_time = Time.now - (5 * 24 * 60 * 60)  # 5 days ago

    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ], committed_at: old_time)
    create_commit_with_author("bob", "bob@example.com", [
      { name: "puma", change_type: "added" }
    ], committed_at: recent_time)

    until_date = (Time.now - (10 * 24 * 60 * 60)).strftime("%Y-%m-%d")  # 10 days ago
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--by-author", "--until=#{until_date}"]).run
      end
    end

    assert_includes output, "alice"
    refute_includes output, "bob"
  end

  def test_stats_default_shows_most_changed
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" },
      { name: "rails", change_type: "modified" },
      { name: "puma", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new([]).run
      end
    end

    assert_includes output, "Most Changed Dependencies"
    assert_includes output, "rails"
    assert_includes output, "2 changes"
    assert_includes output, "puma"
  end

  def test_stats_default_json_format
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" },
      { name: "puma", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert data.key?("most_changed")
    assert_equal 2, data["most_changed"].length
    names = data["most_changed"].map { |d| d["name"] }
    assert_includes names, "rails"
    assert_includes names, "puma"
  end

  def create_commit_with_author(name, email, changes, committed_at: Time.now)
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: "Test commit",
      author_name: name,
      author_email: email,
      committed_at: committed_at,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create(
        commit: commit,
        manifest: manifest,
        name: change[:name],
        change_type: change[:change_type],
        requirement: ">= 0",
        ecosystem: "rubygems",
        dependency_type: "runtime"
      )
    end

    commit
  end

  def test_stats_default_with_current_dependencies
    # Create branch with snapshot to test current_dependencies output
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: "Test",
      author_name: "alice",
      author_email: "alice@example.com",
      committed_at: Time.now,
      has_dependency_changes: true
    )

    branch = Git::Pkgs::Models::Branch.create(name: "main", last_analyzed_sha: sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit, position: 1)

    manifest = Git::Pkgs::Models::Manifest.find_or_create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")

    Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit, manifest: manifest, name: "rails",
      ecosystem: "rubygems", requirement: "~> 7.0", dependency_type: "runtime"
    )
    Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit, manifest: manifest, name: "rspec",
      ecosystem: "rubygems", requirement: "~> 3.0", dependency_type: "development"
    )

    Git::Pkgs::Models::DependencyChange.create(
      commit: commit, manifest: manifest, name: "rails",
      change_type: "added", ecosystem: "rubygems", requirement: "~> 7.0"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new([]).run
      end
    end

    assert_includes output, "Current Dependencies"
    assert_includes output, "Total: 2"
    assert_includes output, "rubygems: 2"
    assert_includes output, "By type:"
    assert_includes output, "runtime: 1"
    assert_includes output, "development: 1"
  end

  def test_stats_filters_by_ecosystem
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ])

    # Create npm change
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha, message: "Add npm", author_name: "bob",
      author_email: "bob@example.com", committed_at: Time.now, has_dependency_changes: true
    )
    npm_manifest = Git::Pkgs::Models::Manifest.find_or_create(path: "package.json", ecosystem: "npm", kind: "manifest")
    Git::Pkgs::Models::DependencyChange.create(
      commit: commit, manifest: npm_manifest, name: "express",
      change_type: "added", ecosystem: "npm", requirement: "^4.0"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--ecosystem=rubygems"]).run
      end
    end

    assert_includes output, "Ecosystem: rubygems"
    assert_includes output, "rails"
    refute_includes output, "express"
  end

  def test_stats_by_author_empty_result
    # No commits with added dependencies
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--by-author"]).run
      end
    end

    assert_includes output, "No dependency additions found"
  end

  def test_stats_by_author_filters_by_ecosystem
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new(["--by-author", "--ecosystem=npm"]).run
      end
    end

    assert_includes output, "No dependency additions found"
  end

  def test_stats_shows_manifest_files
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new([]).run
      end
    end

    assert_includes output, "Manifest Files"
    assert_includes output, "Gemfile"
    assert_includes output, "1 changes"
  end

  def test_stats_shows_top_authors
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" },
      { name: "puma", change_type: "added" }
    ])
    create_commit_with_author("bob", "bob@example.com", [
      { name: "sidekiq", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new([]).run
      end
    end

    assert_includes output, "Top Authors"
    assert_includes output, "alice"
    assert_includes output, "bob"
  end

  def test_stats_shows_changes_by_type
    create_commit_with_author("alice", "alice@example.com", [
      { name: "rails", change_type: "added" },
      { name: "puma", change_type: "modified" },
      { name: "sidekiq", change_type: "removed" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stats.new([]).run
      end
    end

    assert_includes output, "Dependency Changes"
    assert_includes output, "Total changes: 3"
    assert_includes output, "added:"
    assert_includes output, "modified:"
    assert_includes output, "removed:"
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

class Git::Pkgs::TestLogCommand < Git::Pkgs::DatabaseTest
  def setup
    super
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    commit("Add rails")
  end

  def test_log_shows_commits_with_changes
    create_commit_with_changes("First commit", [
      { name: "rails", change_type: "added" }
    ])
    create_commit_with_changes("Second commit", [
      { name: "puma", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Log.new([]).run
      end
    end

    assert_includes output, "First commit"
    assert_includes output, "Second commit"
    assert_includes output, "+ rails"
    assert_includes output, "+ puma"
  end

  def test_log_filters_by_author
    create_commit_with_changes("Alice commit", [
      { name: "rails", change_type: "added" }
    ], author_name: "alice")
    create_commit_with_changes("Bob commit", [
      { name: "puma", change_type: "added" }
    ], author_name: "bob")

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Log.new(["--author=alice"]).run
      end
    end

    assert_includes output, "Alice commit"
    refute_includes output, "Bob commit"
  end

  def test_log_respects_limit
    3.times do |i|
      create_commit_with_changes("Commit #{i}", [
        { name: "gem#{i}", change_type: "added" }
      ])
    end

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Log.new(["-n", "2"]).run
      end
    end

    # Should only show 2 commits
    assert_equal 2, output.scan(/^[a-f0-9]{7} Commit/).length
  end

  def test_log_json_format
    create_commit_with_changes("Test commit", [
      { name: "rails", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Log.new(["--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data.length
    assert_equal "Test commit", data.first["message"]
    assert_equal 1, data.first["changes"].length
  end

  def create_commit_with_changes(message, changes, author_name: "Test User", author_email: "test@example.com")
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: message,
      author_name: author_name,
      author_email: author_email,
      committed_at: Time.now,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create(
        commit: commit,
        manifest: manifest,
        name: change[:name],
        change_type: change[:change_type],
        requirement: ">= 0",
        ecosystem: "rubygems",
        dependency_type: "runtime"
      )
    end

    commit
  end
end

class Git::Pkgs::TestInfoCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    commit("Add rails")
    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def test_info_with_zero_snapshots_does_not_crash
    # Create commits with dependency changes but no snapshots
    sha = SecureRandom.hex(20)
    Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: "Test commit",
      author_name: "Test User",
      author_email: "test@example.com",
      committed_at: Time.now,
      has_dependency_changes: true
    )

    # Should not raise FloatDomainError
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Info.new([]).run
      end
    end

    assert_includes output, "Commits with dependency changes: 1"
    assert_includes output, "Commits with snapshots: 0"
    assert_includes output, "Coverage: 0.0%"
    refute_includes output, "1 snapshot per"
  end

  def test_info_with_snapshots_shows_ratio
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: "Test commit",
      author_name: "Test User",
      author_email: "test@example.com",
      committed_at: Time.now,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit,
      manifest: manifest,
      name: "rails",
      ecosystem: "rubygems",
      requirement: ">= 0",
      dependency_type: "runtime"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Info.new([]).run
      end
    end

    assert_includes output, "Commits with dependency changes: 1"
    assert_includes output, "Commits with snapshots: 1"
    assert_includes output, "Coverage: 100.0%"
  end

  def test_info_shows_database_location_and_size
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Info.new([]).run
      end
    end

    assert_includes output, "Database Info"
    assert_includes output, "Location:"
    assert_includes output, "pkgs.sqlite3"
    assert_includes output, "Size:"
  end

  def test_info_shows_row_counts
    Git::Pkgs::Models::Commit.create(
      sha: SecureRandom.hex(20), message: "Test",
      author_name: "Test", author_email: "test@example.com", committed_at: Time.now
    )
    Git::Pkgs::Models::Manifest.create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Info.new([]).run
      end
    end

    assert_includes output, "Row Counts"
    assert_includes output, "Branches"
    assert_includes output, "Commits"
    assert_includes output, "Manifests"
    assert_includes output, "Dependency Changes"
    assert_includes output, "Total"
  end

  def test_info_shows_branch_info
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha, message: "Test",
      author_name: "Test", author_email: "test@example.com", committed_at: Time.now
    )
    branch = Git::Pkgs::Models::Branch.create(name: "main", last_analyzed_sha: sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit, position: 1)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Info.new([]).run
      end
    end

    assert_includes output, "Branches"
    assert_includes output, "main:"
    assert_includes output, "1 commits"
    assert_includes output, sha[0, 7]
  end

  def test_info_ecosystems_flag
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Info.new(["--ecosystems"]).run
      end
    end

    assert_includes output, "Available Ecosystems"
    assert_includes output, "Enabled:"
    assert_includes output, "rubygems"
    assert_includes output, "npm"
  end

  def test_info_format_size_bytes
    cmd = Git::Pkgs::Commands::Info.new([])
    assert_equal "100.0 B", cmd.send(:format_size, 100)
  end

  def test_info_format_size_kilobytes
    cmd = Git::Pkgs::Commands::Info.new([])
    assert_equal "1.5 KB", cmd.send(:format_size, 1536)
  end

  def test_info_format_size_megabytes
    cmd = Git::Pkgs::Commands::Info.new([])
    assert_equal "2.0 MB", cmd.send(:format_size, 2 * 1024 * 1024)
  end

  def test_info_format_size_gigabytes
    cmd = Git::Pkgs::Commands::Info.new([])
    assert_equal "1.0 GB", cmd.send(:format_size, 1024 * 1024 * 1024)
  end

  def test_info_multiple_branches
    sha1 = SecureRandom.hex(20)
    sha2 = SecureRandom.hex(20)
    commit1 = Git::Pkgs::Models::Commit.create(
      sha: sha1, message: "Test 1",
      author_name: "Test", author_email: "test@example.com", committed_at: Time.now
    )
    commit2 = Git::Pkgs::Models::Commit.create(
      sha: sha2, message: "Test 2",
      author_name: "Test", author_email: "test@example.com", committed_at: Time.now
    )

    branch1 = Git::Pkgs::Models::Branch.create(name: "main", last_analyzed_sha: sha1)
    branch2 = Git::Pkgs::Models::Branch.create(name: "develop", last_analyzed_sha: sha2)
    Git::Pkgs::Models::BranchCommit.create(branch: branch1, commit: commit1, position: 1)
    Git::Pkgs::Models::BranchCommit.create(branch: branch2, commit: commit2, position: 1)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Info.new([]).run
      end
    end

    assert_includes output, "main:"
    assert_includes output, "develop:"
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

class Git::Pkgs::TestWhereCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", sample_gemfile({ "rails" => "~> 7.0", "puma" => "~> 5.0" }))
    commit("Add dependencies")
    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema

    # Create branch and snapshot
    repo = Git::Pkgs::Repository.new(@test_dir)
    Git::Pkgs::Models::Branch.create(name: repo.default_branch, last_analyzed_sha: repo.head_sha)
    rugged_commit = repo.lookup(repo.head_sha)
    commit_record = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)

    manifest = Git::Pkgs::Models::Manifest.create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit_record,
      manifest: manifest,
      name: "rails",
      ecosystem: "rubygems",
      requirement: "~> 7.0"
    )

    Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit_record,
      manifest: manifest,
      name: "puma",
      ecosystem: "rubygems",
      requirement: "~> 5.0"
    )
  end

  def teardown
    cleanup_test_repo
  end

  def test_where_finds_package_in_manifest
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Where.new(["rails"]).run
      end
    end

    assert_includes output, "Gemfile"
    assert_includes output, "rails"
  end

  def test_where_shows_line_number
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Where.new(["rails"]).run
      end
    end

    # Output format: path:line:content
    assert_match(/Gemfile:\d+:.*rails/, output)
  end

  def test_where_not_found
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Where.new(["nonexistent"]).run
      end
    end

    assert_includes output, "not found"
  end

  def test_where_json_format
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Where.new(["rails", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data.length
    assert_equal "Gemfile", data.first["path"]
    assert data.first["line"].is_a?(Integer)
    assert_includes data.first["content"], "rails"
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

class Git::Pkgs::TestSchemaCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    commit("Add rails")
    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def test_schema_text_format
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Schema.new([]).run
      end
    end

    assert_includes output, "commits"
    assert_includes output, "dependency_changes"
    assert_includes output, "manifests"
    assert_includes output, "sha"
  end

  def test_schema_sql_format
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Schema.new(["--format=sql"]).run
      end
    end

    assert_includes output, "CREATE TABLE"
    assert_includes output, "commits"
  end

  def test_schema_json_format
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Schema.new(["--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert data.key?("commits")
    assert data.key?("dependency_changes")
    assert data["commits"]["columns"].any? { |c| c["name"] == "sha" }
  end

  def test_schema_markdown_format
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Schema.new(["--format=markdown"]).run
      end
    end

    assert_includes output, "## commits"
    assert_includes output, "| Column | Type |"
    assert_includes output, "| sha |"
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

# Shared test base for command integration tests
class Git::Pkgs::CommandTestBase < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    commit("Add rails")
    @git_dir = File.join(@test_dir, ".git")

    # Delete any existing database and create fresh
    db_path = File.join(@git_dir, "pkgs.sqlite3")
    File.delete(db_path) if File.exist?(db_path)

    Git::Pkgs::Database.connect(@git_dir, check_version: false)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def create_commit_with_changes(author, changes, message: "Test commit", committed_at: Time.now)
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha,
      message: message,
      author_name: author,
      author_email: "#{author}@example.com",
      committed_at: committed_at,
      has_dependency_changes: changes.any?
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create(
        commit: commit,
        manifest: manifest,
        name: change[:name],
        change_type: change[:change_type],
        requirement: change[:requirement] || ">= 0",
        ecosystem: "rubygems",
        dependency_type: change[:dependency_type] || "runtime"
      )
    end

    commit
  end

  def create_branch_with_snapshot(branch_name, commit, dependencies)
    branch = Git::Pkgs::Models::Branch.create(name: branch_name, last_analyzed_sha: commit.sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit, position: 1)

    manifest = Git::Pkgs::Models::Manifest.find_or_create(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    dependencies.each do |dep|
      Git::Pkgs::Models::DependencySnapshot.create(
        commit: commit,
        manifest: manifest,
        name: dep[:name],
        ecosystem: "rubygems",
        requirement: dep[:requirement] || ">= 0",
        dependency_type: dep[:dependency_type] || "runtime"
      )
    end

    branch
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end

class Git::Pkgs::TestSearchCommand < Git::Pkgs::CommandTestBase
  def test_search_finds_matching_dependencies
    create_commit_with_changes("alice", [
      { name: "rails", change_type: "added" },
      { name: "railties", change_type: "added" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Search.new(["rail"]).run
      end
    end

    assert_includes output, "rails"
    assert_includes output, "railties"
  end

  def test_search_not_found
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Search.new(["nonexistent"]).run
      end
    end

    assert_includes output, "No dependencies found"
  end

  def test_search_requires_pattern
    assert_raises(SystemExit) do
      capture_stderr do
        Dir.chdir(@test_dir) do
          Git::Pkgs::Commands::Search.new([]).run
        end
      end
    end
  end

  def test_search_filters_by_ecosystem
    create_commit_with_changes("alice", [{ name: "rails", change_type: "added" }])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Search.new(["rails", "--ecosystem=npm"]).run
      end
    end

    assert_includes output, "No dependencies found"
  end
end

class Git::Pkgs::TestWhyCommand < Git::Pkgs::CommandTestBase
  def test_why_shows_when_package_was_added
    create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0" }
    ], message: "Add rails for web framework")

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Why.new(["rails"]).run
      end
    end

    assert_includes output, "rails was added"
    assert_includes output, "alice"
    assert_includes output, "Add rails for web framework"
    assert_includes output, "~> 7.0"
  end

  def test_why_package_not_found
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Why.new(["nonexistent"]).run
      end
    end

    assert_includes output, "not found"
  end

  def test_why_finds_earliest_add
    old_time = Time.now - (30 * 24 * 60 * 60)
    recent_time = Time.now - (5 * 24 * 60 * 60)

    create_commit_with_changes("alice", [
      { name: "rails", change_type: "added" }
    ], committed_at: old_time)

    create_commit_with_changes("bob", [
      { name: "rails", change_type: "modified" }
    ], committed_at: recent_time)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Why.new(["rails"]).run
      end
    end

    assert_includes output, "alice"
    refute_includes output, "bob"
  end

  def test_why_json_format
    create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0" }
    ], message: "Add rails for web framework")

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Why.new(["rails", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal true, data["found"]
    assert_equal "rails", data["package"]
    assert_equal "rubygems", data["ecosystem"]
    assert_equal "~> 7.0", data["requirement"]
    assert_equal "Gemfile", data["manifest"]
    assert_equal "alice", data["commit"]["author_name"]
    assert_equal "Add rails for web framework", data["commit"]["message"]
    assert data["commit"].key?("sha")
    assert data["commit"].key?("date")
  end

  def test_why_json_format_not_found
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Why.new(["nonexistent", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal false, data["found"]
    assert_equal "nonexistent", data["package"]
  end
end

class Git::Pkgs::TestBlameCommand < Git::Pkgs::CommandTestBase
  def test_blame_shows_who_added_dependencies
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0" }
    ])
    create_branch_with_snapshot("main", commit, [
      { name: "rails", requirement: "~> 7.0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Blame.new([]).run
      end
    end

    assert_includes output, "rails"
    assert_includes output, "alice"
  end

  def test_blame_json_format
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0" }
    ])
    create_branch_with_snapshot("main", commit, [
      { name: "rails", requirement: "~> 7.0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Blame.new(["--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data.length
    assert_equal "rails", data.first["name"]
    assert_equal "alice", data.first["author"]
  end

  def test_blame_prefers_human_over_bot
    commit = create_commit_with_changes("dependabot[bot]", [
      { name: "rails", change_type: "added" }
    ], message: "Bump rails\n\nCo-authored-by: Alice <alice@example.com>")
    create_branch_with_snapshot("main", commit, [{ name: "rails" }])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Blame.new([]).run
      end
    end

    assert_includes output, "Alice"
  end
end

class Git::Pkgs::TestListCommand < Git::Pkgs::CommandTestBase
  def test_list_shows_dependencies_at_commit
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0" }
    ])
    create_branch_with_snapshot("main", commit, [
      { name: "rails", requirement: "~> 7.0", dependency_type: "runtime" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::List.new(["--commit=#{commit.sha}"]).run
      end
    end

    assert_includes output, "Gemfile"
    assert_includes output, "rails"
    assert_includes output, "~> 7.0"
  end

  def test_list_json_format
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0" }
    ])
    create_branch_with_snapshot("main", commit, [
      { name: "rails", requirement: "~> 7.0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::List.new(["--commit=#{commit.sha}", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data.length
    assert_equal "rails", data.first["name"]
    assert_equal "~> 7.0", data.first["requirement"]
  end

  def test_list_filters_by_ecosystem
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added" }
    ])
    create_branch_with_snapshot("main", commit, [{ name: "rails" }])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::List.new(["--commit=#{commit.sha}", "--ecosystem=npm"]).run
      end
    end

    assert_includes output, "No dependencies found"
  end

  def test_list_filters_by_manifest
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha, message: "Add deps",
      author_name: "alice", author_email: "alice@example.com",
      committed_at: Time.now, has_dependency_changes: true
    )

    gemfile = Git::Pkgs::Models::Manifest.find_or_create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")
    package_json = Git::Pkgs::Models::Manifest.find_or_create(path: "package.json", ecosystem: "npm", kind: "manifest")

    branch = Git::Pkgs::Models::Branch.create(name: "main", last_analyzed_sha: sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit, position: 1)

    Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit, manifest: gemfile, name: "rails",
      ecosystem: "rubygems", requirement: "~> 7.0", dependency_type: "runtime"
    )
    Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit, manifest: package_json, name: "lodash",
      ecosystem: "npm", requirement: "^4.0", dependency_type: "runtime"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::List.new(["--commit=#{sha}", "--manifest=Gemfile"]).run
      end
    end

    assert_includes output, "rails"
    refute_includes output, "lodash"
  end

  def test_list_manifest_filter_no_match
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added" }
    ])
    create_branch_with_snapshot("main", commit, [{ name: "rails" }])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::List.new(["--commit=#{commit.sha}", "--manifest=package.json"]).run
      end
    end

    assert_includes output, "No dependencies found"
  end

  def test_list_manifest_filter_json_format
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha, message: "Add deps",
      author_name: "alice", author_email: "alice@example.com",
      committed_at: Time.now, has_dependency_changes: true
    )

    gemfile = Git::Pkgs::Models::Manifest.find_or_create(path: "Gemfile", ecosystem: "rubygems", kind: "manifest")
    package_json = Git::Pkgs::Models::Manifest.find_or_create(path: "package.json", ecosystem: "npm", kind: "manifest")

    branch = Git::Pkgs::Models::Branch.create(name: "main", last_analyzed_sha: sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit, position: 1)

    Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit, manifest: gemfile, name: "rails",
      ecosystem: "rubygems", requirement: "~> 7.0", dependency_type: "runtime"
    )
    Git::Pkgs::Models::DependencySnapshot.create(
      commit: commit, manifest: package_json, name: "lodash",
      ecosystem: "npm", requirement: "^4.0", dependency_type: "runtime"
    )

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::List.new(["--commit=#{sha}", "--manifest=Gemfile", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data.length
    assert_equal "rails", data.first["name"]
    assert_equal "Gemfile", data.first["manifest_path"]
  end
end

class Git::Pkgs::TestStaleCommand < Git::Pkgs::CommandTestBase
  def test_stale_shows_dependencies_by_last_update
    old_time = Time.now - (100 * 24 * 60 * 60)  # 100 days ago
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0" }
    ], committed_at: old_time)
    create_branch_with_snapshot("main", commit, [
      { name: "rails", requirement: "~> 7.0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stale.new([]).run
      end
    end

    assert_includes output, "rails"
    assert_includes output, "days ago"
  end

  def test_stale_filters_by_days
    recent_time = Time.now - (5 * 24 * 60 * 60)  # 5 days ago
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added" }
    ], committed_at: recent_time)
    create_branch_with_snapshot("main", commit, [{ name: "rails" }])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stale.new(["--days=30"]).run
      end
    end

    assert_includes output, "updated recently"
  end

  def test_stale_json_format
    old_time = Time.now - (100 * 24 * 60 * 60)  # 100 days ago
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0" }
    ], committed_at: old_time)
    create_branch_with_snapshot("main", commit, [
      { name: "rails", requirement: "~> 7.0" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stale.new(["--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data.length
    assert_equal "rails", data.first["name"]
    assert_equal "rubygems", data.first["ecosystem"]
    assert_equal "~> 7.0", data.first["requirement"]
    assert data.first["days_ago"] >= 99
    assert data.first.key?("last_updated")
  end

  def test_stale_json_format_empty
    recent_time = Time.now - (5 * 24 * 60 * 60)  # 5 days ago
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added" }
    ], committed_at: recent_time)
    create_branch_with_snapshot("main", commit, [{ name: "rails" }])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stale.new(["--days=30", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal [], data
  end

  def test_stale_filters_by_ecosystem
    old_time = Time.now - (100 * 24 * 60 * 60)
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", ecosystem: "rubygems" }
    ], committed_at: old_time)
    create_branch_with_snapshot("main", commit, [
      { name: "rails", ecosystem: "rubygems" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stale.new(["--ecosystem=npm"]).run
      end
    end

    assert_includes output, "No dependencies found"
  end

  def test_stale_no_dependencies
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create(
      sha: sha, message: "Empty",
      author_name: "alice", author_email: "alice@example.com",
      committed_at: Time.now, has_dependency_changes: false
    )
    branch = Git::Pkgs::Models::Branch.create(name: "main", last_analyzed_sha: sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit, position: 1)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stale.new([]).run
      end
    end

    assert_includes output, "No dependencies found"
  end

  def test_stale_no_branch_analysis
    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Stale.new(["--branch=nonexistent"]).run
        end
      end
    end

    assert_includes output, "No analysis found"
  end

  def test_stale_text_output_formatting
    old_time = Time.now - (50 * 24 * 60 * 60)  # 50 days ago
    recent_time = Time.now - (10 * 24 * 60 * 60)  # 10 days ago

    commit1 = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0" }
    ], committed_at: old_time)
    commit2 = create_commit_with_changes("bob", [
      { name: "puma", change_type: "added", requirement: "~> 6.0" }
    ], committed_at: recent_time)

    create_branch_with_snapshot("main", commit2, [
      { name: "rails", requirement: "~> 7.0" },
      { name: "puma", requirement: "~> 6.0" }
    ])

    # Re-associate rails change with older commit
    rails_change = Git::Pkgs::Models::DependencyChange.first(name: "rails")
    rails_change.update(commit: commit1)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Stale.new([]).run
      end
    end

    assert_includes output, "Dependencies by last update"
    assert_includes output, "rails"
    assert_includes output, "puma"
    # Rails should appear first (older)
    assert output.index("rails") < output.index("puma")
  end
end

class Git::Pkgs::TestTreeCommand < Git::Pkgs::CommandTestBase
  def test_tree_shows_dependency_tree
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0", dependency_type: "runtime" },
      { name: "rspec", change_type: "added", requirement: "~> 3.0", dependency_type: "development" }
    ])
    create_branch_with_snapshot("main", commit, [
      { name: "rails", requirement: "~> 7.0", dependency_type: "runtime" },
      { name: "rspec", requirement: "~> 3.0", dependency_type: "development" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Tree.new([]).run
      end
    end

    assert_includes output, "Gemfile"
    assert_includes output, "rails"
    assert_includes output, "rspec"
    assert_includes output, "runtime"
    assert_includes output, "development"
  end

  def test_tree_filters_by_ecosystem
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added" }
    ])
    create_branch_with_snapshot("main", commit, [{ name: "rails" }])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Tree.new(["--ecosystem=npm"]).run
      end
    end

    assert_includes output, "No dependencies found"
  end

  def test_tree_json_format
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0", dependency_type: "runtime" },
      { name: "rspec", change_type: "added", requirement: "~> 3.0", dependency_type: "development" }
    ])
    create_branch_with_snapshot("main", commit, [
      { name: "rails", requirement: "~> 7.0", dependency_type: "runtime" },
      { name: "rspec", requirement: "~> 3.0", dependency_type: "development" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Tree.new(["--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal 1, data["manifests"].length
    assert_equal "Gemfile", data["manifests"].first["path"]
    assert_equal "rubygems", data["manifests"].first["ecosystem"]
    assert data["manifests"].first["dependencies"].key?("runtime")
    assert data["manifests"].first["dependencies"].key?("development")
    assert_equal 2, data["total"]
  end

  def test_tree_json_format_filters_to_empty
    commit = create_commit_with_changes("alice", [
      { name: "rails", change_type: "added", requirement: "~> 7.0", dependency_type: "runtime" }
    ])
    create_branch_with_snapshot("main", commit, [
      { name: "rails", requirement: "~> 7.0", dependency_type: "runtime" }
    ])

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Tree.new(["--ecosystem=npm", "--format=json"]).run
      end
    end

    data = JSON.parse(output)
    assert_equal [], data["manifests"]
    assert_equal 0, data["total"]
  end
end

class Git::Pkgs::TestHooksCommand < Git::Pkgs::CommandTestBase
  def test_hooks_install
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Hooks.new(["--install"]).run
      end
    end

    assert_includes output, "Installed hooks"
    assert File.exist?(File.join(@git_dir, "hooks", "post-commit"))
    assert File.exist?(File.join(@git_dir, "hooks", "post-merge"))
  end

  def test_hooks_status
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Hooks.new([]).run
      end
    end

    assert_includes output, "Hook status"
    assert_includes output, "post-commit"
  end

  def test_hooks_uninstall
    Dir.chdir(@test_dir) do
      capture_stdout { Git::Pkgs::Commands::Hooks.new(["--install"]).run }
    end

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Hooks.new(["--uninstall"]).run
      end
    end

    assert_includes output, "uninstalled"
    refute File.exist?(File.join(@git_dir, "hooks", "post-commit"))
  end

  def test_hooks_already_installed_is_silent
    Dir.chdir(@test_dir) do
      capture_stdout { Git::Pkgs::Commands::Hooks.new(["--install"]).run }
    end

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Hooks.new(["--install"]).run
      end
    end

    # Should not say "Installed hooks" again
    refute_includes output, "Installed hooks"
  end
end

class Git::Pkgs::TestBranchCommand < Git::Pkgs::CommandTestBase
  def test_branch_list_empty
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Branch.new(["list"]).run
      end
    end

    assert_includes output, "No branches tracked"
  end

  def test_branch_list_shows_tracked_branches
    commit = create_commit_with_changes("alice", [{ name: "rails", change_type: "added" }])
    branch = Git::Pkgs::Models::Branch.create(name: "main", last_analyzed_sha: commit.sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit, position: 1)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Branch.new(["list"]).run
      end
    end

    assert_includes output, "Tracked branches"
    assert_includes output, "main"
  end

  def test_branch_remove
    commit = create_commit_with_changes("alice", [{ name: "rails", change_type: "added" }])
    branch = Git::Pkgs::Models::Branch.create(name: "feature", last_analyzed_sha: commit.sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit, position: 1)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Branch.new(["remove", "feature"]).run
      end
    end

    assert_includes output, "Removed branch 'feature'"
    assert_nil Git::Pkgs::Models::Branch.first(name: "feature")
  end

  def test_branch_remove_not_tracked
    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Branch.new(["remove", "nonexistent"]).run
        end
      end
    end

    assert_includes output, "not tracked"
  end

  def test_branch_help
    output = capture_stdout do
      Git::Pkgs::Commands::Branch.new(["--help"]).run
    end

    assert_includes output, "Usage:"
    assert_includes output, "add <name>"
    assert_includes output, "list"
    assert_includes output, "remove <name>"
  end

  def test_branch_unknown_subcommand
    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Branch.new(["unknown"]).run
        end
      end
    end

    assert_includes output, "Unknown subcommand"
  end

  def test_branch_add_already_tracked
    commit = create_commit_with_changes("alice", [{ name: "rails", change_type: "added" }])
    Git::Pkgs::Models::Branch.create(name: "main", last_analyzed_sha: commit.sha)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Branch.new(["add", "main"]).run
      end
    end

    assert_includes output, "already tracked"
  end

  def test_branch_add_not_found
    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Branch.new(["add", "nonexistent-branch"]).run
        end
      end
    end

    assert_includes output, "not found"
  end

  def test_branch_list_shows_dependency_commit_count
    commit1 = create_commit_with_changes("alice", [{ name: "rails", change_type: "added" }])
    commit2 = Git::Pkgs::Models::Commit.create(
      sha: SecureRandom.hex(20), message: "No deps",
      author_name: "bob", author_email: "bob@example.com",
      committed_at: Time.now, has_dependency_changes: false
    )
    branch = Git::Pkgs::Models::Branch.create(name: "main", last_analyzed_sha: commit1.sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit1, position: 1)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit2, position: 2)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Branch.new(["list"]).run
      end
    end

    assert_includes output, "2 commits"
    assert_includes output, "1 with deps"
  end

  def test_branch_remove_no_name
    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Branch.new(["remove"]).run
        end
      end
    end

    assert_includes output, "Usage:"
  end

  def test_branch_add_no_name
    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Branch.new(["add"]).run
        end
      end
    end

    assert_includes output, "Usage:"
  end

  def test_branch_default_config
    cmd = Git::Pkgs::Commands::Branch.new([])
    assert_equal 500, cmd.batch_size
    assert_equal 50, cmd.snapshot_interval
  end

  def test_branch_no_subcommand_shows_help
    output = capture_stdout do
      Git::Pkgs::Commands::Branch.new([]).run
    end

    assert_includes output, "Usage:"
    assert_includes output, "Subcommands:"
  end

  def test_branch_rm_alias
    commit = create_commit_with_changes("alice", [{ name: "rails", change_type: "added" }])
    branch = Git::Pkgs::Models::Branch.create(name: "feature", last_analyzed_sha: commit.sha)
    Git::Pkgs::Models::BranchCommit.create(branch: branch, commit: commit, position: 1)

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Branch.new(["rm", "feature"]).run
      end
    end

    assert_includes output, "Removed branch 'feature'"
  end
end

class Git::Pkgs::TestInitCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", sample_gemfile({ "rails" => "~> 7.0" }))
    commit("Add rails")
  end

  def teardown
    cleanup_test_repo
  end

  def test_init_creates_database
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Init.new(["--no-hooks"]).run
      end
    end

    assert_includes output, "Analyzed"
    assert_includes output, "main"
    assert File.exist?(File.join(@test_dir, ".git", "pkgs.sqlite3"))
  end

  def test_init_force_rebuilds
    Dir.chdir(@test_dir) do
      capture_stdout { Git::Pkgs::Commands::Init.new(["--no-hooks"]).run }
    end

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Init.new(["--force", "--no-hooks"]).run
      end
    end

    assert_includes output, "Analyzed"
  end

  def test_init_reports_dependency_commits
    add_file("Gemfile", sample_gemfile({ "rails" => "~> 7.0", "puma" => "~> 6.0" }))
    commit("Add puma")

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Init.new(["--no-hooks"]).run
      end
    end

    assert_match(/\d+ with dependency changes/, output)
  end

  def test_init_already_exists_without_force
    Dir.chdir(@test_dir) do
      capture_stdout { Git::Pkgs::Commands::Init.new(["--no-hooks"]).run }
    end

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Init.new(["--no-hooks"]).run
      end
    end

    assert_includes output, "already exists"
    assert_includes output, "--force"
  end

  def test_init_branch_not_found
    output = capture_stderr do
      Dir.chdir(@test_dir) do
        assert_raises(SystemExit) do
          Git::Pkgs::Commands::Init.new(["--branch=nonexistent", "--no-hooks"]).run
        end
      end
    end

    assert_includes output, "not found"
  end

  def test_init_with_specific_branch
    Dir.chdir(@test_dir) do
      system("git checkout -b feature", out: File::NULL, err: File::NULL)
      add_file("Gemfile", sample_gemfile({ "rails" => "~> 7.0", "puma" => "~> 6.0" }))
      commit("Add puma on feature")
    end

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Init.new(["--branch=feature", "--no-hooks"]).run
      end
    end

    assert_includes output, "feature"
  end

  def test_init_quiet_mode
    Git::Pkgs.quiet = true

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Init.new(["--no-hooks"]).run
      end
    end

    assert_equal "", output
  ensure
    Git::Pkgs.quiet = false
  end

  def test_init_batch_size_and_snapshot_interval
    cmd = Git::Pkgs::Commands::Init.new([])
    assert_equal 500, cmd.batch_size
    assert_equal 50, cmd.snapshot_interval
  end

  def test_init_custom_batch_size
    Git::Pkgs.batch_size = 100
    cmd = Git::Pkgs::Commands::Init.new([])
    assert_equal 100, cmd.batch_size
  ensure
    Git::Pkgs.batch_size = nil
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end

class Git::Pkgs::TestUpdateCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", sample_gemfile({ "rails" => "~> 7.0" }))
    commit("Add rails")
    @git_dir = File.join(@test_dir, ".git")

    Dir.chdir(@test_dir) do
      capture_stdout { Git::Pkgs::Commands::Init.new(["--no-hooks"]).run }
    end
  end

  def teardown
    cleanup_test_repo
  end

  def test_update_already_current
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Update.new([]).run
      end
    end

    assert_includes output, "Already up to date"
  end

  def test_update_processes_new_commits
    add_file("Gemfile", sample_gemfile({ "rails" => "~> 7.0", "puma" => "~> 6.0" }))
    commit("Add puma")

    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Update.new([]).run
      end
    end

    assert_includes output, "Updated"
    assert_includes output, "1 commit"
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

class Git::Pkgs::TestUpgradeCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("Gemfile", sample_gemfile({ "rails" => "~> 7.0" }))
    commit("Add rails")
    @git_dir = File.join(@test_dir, ".git")

    Dir.chdir(@test_dir) do
      capture_stdout { Git::Pkgs::Commands::Init.new(["--no-hooks"]).run }
    end
  end

  def teardown
    cleanup_test_repo
  end

  def test_upgrade_already_current
    output = capture_stdout do
      Dir.chdir(@test_dir) do
        Git::Pkgs::Commands::Upgrade.new([]).run
      end
    end

    assert_includes output, "up to date"
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

class Git::Pkgs::TestCompletionsCommand < Minitest::Test
  include TestHelpers

  def setup
    @original_home = ENV["HOME"]
    @temp_home = Dir.mktmpdir
    ENV["HOME"] = @temp_home
  end

  def teardown
    ENV["HOME"] = @original_home
    FileUtils.rm_rf(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def test_completions_bash_output
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["bash"]).run
    end

    assert_includes output, "_git_pkgs()"
    assert_includes output, "COMPREPLY"
    assert_includes output, "complete -F _git_pkgs git-pkgs"
  end

  def test_completions_zsh_output
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["zsh"]).run
    end

    assert_includes output, "#compdef git-pkgs"
    assert_includes output, "_git-pkgs()"
    assert_includes output, "commands=("
  end

  def test_completions_help
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["--help"]).run
    end

    assert_includes output, "Usage: git pkgs completions"
    assert_includes output, "bash"
    assert_includes output, "zsh"
    assert_includes output, "install"
  end

  def test_completions_nil_shows_help
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new([]).run
    end

    assert_includes output, "Usage: git pkgs completions"
  end

  def test_completions_unknown_shell_error
    output = capture_stderr do
      assert_raises(SystemExit) do
        Git::Pkgs::Commands::Completions.new(["fish"]).run
      end
    end

    assert_includes output, "Unknown shell: fish"
    assert_includes output, "Supported: bash, zsh"
  end

  def test_completions_install_bash
    original_shell = ENV["SHELL"]
    ENV["SHELL"] = "/bin/bash"

    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["install"]).run
    end

    assert_includes output, "Installed bash completions"
    completion_path = File.join(@temp_home, ".local/share/bash-completion/completions/git-pkgs")
    assert File.exist?(completion_path)
    assert_includes File.read(completion_path), "_git_pkgs()"
  ensure
    ENV["SHELL"] = original_shell
  end

  def test_completions_install_zsh
    original_shell = ENV["SHELL"]
    ENV["SHELL"] = "/bin/zsh"

    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["install"]).run
    end

    assert_includes output, "Installed zsh completions"
    completion_path = File.join(@temp_home, ".zsh/completions/_git-pkgs")
    assert File.exist?(completion_path)
    assert_includes File.read(completion_path), "#compdef git-pkgs"
  ensure
    ENV["SHELL"] = original_shell
  end

  def test_completions_install_unknown_shell
    original_shell = ENV["SHELL"]
    ENV["SHELL"] = "/bin/unknown"

    output = capture_stderr do
      assert_raises(SystemExit) do
        Git::Pkgs::Commands::Completions.new(["install"]).run
      end
    end

    assert_includes output, "Could not detect shell"
  ensure
    ENV["SHELL"] = original_shell
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end

class Git::Pkgs::TestDiffDriverCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    @git_dir = File.join(@test_dir, ".git")
  end

  def teardown
    cleanup_test_repo
  end

  def test_diff_driver_textconv_gemfile_lock
    gemfile_lock = <<~LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rails (7.0.0)
          nokogiri (1.15.0)

      PLATFORMS
        ruby

      DEPENDENCIES
        rails
        nokogiri

      BUNDLED WITH
        2.4.0
    LOCK

    lockfile_path = File.join(@test_dir, "Gemfile.lock")
    File.write(lockfile_path, gemfile_lock)

    output = capture_stdout do
      Git::Pkgs::Commands::DiffDriver.new([lockfile_path]).run
    end

    assert_includes output, "nokogiri"
    assert_includes output, "rails"
  end

  def test_diff_driver_empty_file
    empty_path = File.join(@test_dir, "empty.lock")
    File.write(empty_path, "")

    output = capture_stdout do
      Git::Pkgs::Commands::DiffDriver.new([empty_path]).run
    end

    assert_equal "", output
  end

  def test_diff_driver_dev_null
    output = capture_stdout do
      Git::Pkgs::Commands::DiffDriver.new(["/dev/null"]).run
    end

    assert_equal "", output
  end

  def test_diff_driver_nonexistent_file
    output = capture_stdout do
      Git::Pkgs::Commands::DiffDriver.new(["/nonexistent/file.lock"]).run
    end

    assert_equal "", output
  end

  def test_diff_driver_install
    Dir.chdir(@test_dir) do
      output = capture_stdout do
        Git::Pkgs::Commands::DiffDriver.new(["--install"]).run
      end

      assert_includes output, "Installed textconv driver"

      gitattributes = File.read(File.join(@test_dir, ".gitattributes"))
      assert_includes gitattributes, "Gemfile.lock diff=pkgs"
      assert_includes gitattributes, "package-lock.json diff=pkgs"
    end
  end

  def test_diff_driver_install_idempotent
    Dir.chdir(@test_dir) do
      # First install
      capture_stdout { Git::Pkgs::Commands::DiffDriver.new(["--install"]).run }
      first_content = File.read(File.join(@test_dir, ".gitattributes"))

      # Second install should not duplicate entries
      capture_stdout { Git::Pkgs::Commands::DiffDriver.new(["--install"]).run }
      second_content = File.read(File.join(@test_dir, ".gitattributes"))

      assert_equal first_content, second_content
    end
  end

  def test_diff_driver_uninstall
    Dir.chdir(@test_dir) do
      # First install
      capture_stdout { Git::Pkgs::Commands::DiffDriver.new(["--install"]).run }

      # Then uninstall
      output = capture_stdout do
        Git::Pkgs::Commands::DiffDriver.new(["--uninstall"]).run
      end

      assert_includes output, "Uninstalled diff driver"

      gitattributes = File.read(File.join(@test_dir, ".gitattributes"))
      refute_includes gitattributes, "diff=pkgs"
    end
  end

  def test_diff_driver_help
    output = capture_stdout do
      assert_raises(SystemExit) do
        Git::Pkgs::Commands::DiffDriver.new(["--help"]).run
      end
    end

    assert_includes output, "Usage: git pkgs diff-driver"
    assert_includes output, "--install"
    assert_includes output, "--uninstall"
  end

  def test_diff_driver_no_args_error
    output = capture_stderr do
      assert_raises(SystemExit) do
        Git::Pkgs::Commands::DiffDriver.new([]).run
      end
    end

    assert_includes output, "Usage: git pkgs diff-driver"
  end

  def test_diff_driver_shows_dependency_type
    package_lock = <<~JSON
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "": {
            "name": "test-project",
            "dependencies": {
              "lodash": "^4.17.21"
            },
            "devDependencies": {
              "jest": "^29.0.0"
            }
          },
          "node_modules/lodash": {
            "version": "4.17.21"
          },
          "node_modules/jest": {
            "version": "29.0.0",
            "dev": true
          }
        }
      }
    JSON

    lockfile_path = File.join(@test_dir, "package-lock.json")
    File.write(lockfile_path, package_lock)

    output = capture_stdout do
      Git::Pkgs::Commands::DiffDriver.new([lockfile_path]).run
    end

    # Should include dependencies
    assert_includes output, "lodash"
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
