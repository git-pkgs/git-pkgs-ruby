# frozen_string_literal: true

require "test_helper"
require "stringio"

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
    Git::Pkgs::Models::Commit.create!(
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
    assert_nil Git::Pkgs::Models::Commit.find_by(sha: sha)

    result = Git::Pkgs::Models::Commit.find_or_create_from_repo(repo, sha)

    assert result
    assert_equal sha, result.sha
    # Verify it was persisted
    assert Git::Pkgs::Models::Commit.find_by(sha: sha)
  end

  def test_find_or_create_from_repo_returns_nil_for_invalid_sha
    repo = Git::Pkgs::Repository.new(@test_dir)

    result = Git::Pkgs::Models::Commit.find_or_create_from_repo(repo, "0000000000000000000000000000000000000000")

    assert_nil result
  end
end

class Git::Pkgs::TestShowCommand < Minitest::Test
  include TestHelpers

  def setup
    create_test_repo
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    commit("Add rails")
    @first_sha = get_head_sha
    add_file("Gemfile", "source 'https://rubygems.org'\ngem 'rails'\ngem 'puma'")
    commit("Add puma")
    @second_sha = get_head_sha
    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
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
    commit = Git::Pkgs::Models::Commit.create!(
      sha: sha,
      message: "Test commit",
      author_name: "Test User",
      author_email: "test@example.com",
      committed_at: Time.now,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.create!(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create!(
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
    commit = Git::Pkgs::Models::Commit.create!(
      sha: sha,
      message: "Test commit",
      author_name: name,
      author_email: email,
      committed_at: Time.now,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create_by!(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create!(
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
    commit = Git::Pkgs::Models::Commit.create!(
      sha: sha,
      message: "Test commit",
      author_name: "Test User",
      author_email: "test@example.com",
      committed_at: time,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create_by!(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create!(
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

  def create_commit_with_author(name, email, changes, committed_at: Time.now)
    sha = SecureRandom.hex(20)
    commit = Git::Pkgs::Models::Commit.create!(
      sha: sha,
      message: "Test commit",
      author_name: name,
      author_email: email,
      committed_at: committed_at,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create_by!(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create!(
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

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end

class Git::Pkgs::TestLogCommand < Minitest::Test
  include TestHelpers

  def setup
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
    commit = Git::Pkgs::Models::Commit.create!(
      sha: sha,
      message: message,
      author_name: author_name,
      author_email: author_email,
      committed_at: Time.now,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.find_or_create_by!(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    changes.each do |change|
      Git::Pkgs::Models::DependencyChange.create!(
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

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end

class Git::Pkgs::TestInfoCommand < Minitest::Test
  include TestHelpers

  def setup
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
    Git::Pkgs::Models::Commit.create!(
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
    commit = Git::Pkgs::Models::Commit.create!(
      sha: sha,
      message: "Test commit",
      author_name: "Test User",
      author_email: "test@example.com",
      committed_at: Time.now,
      has_dependency_changes: true
    )

    manifest = Git::Pkgs::Models::Manifest.create!(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    Git::Pkgs::Models::DependencySnapshot.create!(
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
    create_test_repo
    add_file("Gemfile", sample_gemfile({ "rails" => "~> 7.0", "puma" => "~> 5.0" }))
    commit("Add dependencies")
    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema

    # Create branch and snapshot
    repo = Git::Pkgs::Repository.new(@test_dir)
    Git::Pkgs::Models::Branch.create!(name: repo.default_branch, last_analyzed_sha: repo.head_sha)
    rugged_commit = repo.lookup(repo.head_sha)
    commit_record = Git::Pkgs::Models::Commit.find_or_create_from_rugged(rugged_commit)

    manifest = Git::Pkgs::Models::Manifest.create!(
      path: "Gemfile",
      ecosystem: "rubygems",
      kind: "manifest"
    )

    Git::Pkgs::Models::DependencySnapshot.create!(
      commit: commit_record,
      manifest: manifest,
      name: "rails",
      ecosystem: "rubygems",
      requirement: "~> 7.0"
    )

    Git::Pkgs::Models::DependencySnapshot.create!(
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
