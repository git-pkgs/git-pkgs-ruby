# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class Git::Pkgs::TestOutdatedCommand < Minitest::Test
  include TestHelpers

  def setup
    create_test_repo
    add_file("README.md", "# Test")
    commit("Initial commit")

    @git_dir = File.join(@test_dir, ".git")
    WebMock.disable_net_connect!
  end

  def teardown
    cleanup_test_repo
    WebMock.allow_net_connect!
  end

  def test_classify_update_major
    cmd = Git::Pkgs::Commands::Outdated.new([])

    assert_equal :major, cmd.classify_update("1.0.0", "2.0.0")
    assert_equal :major, cmd.classify_update("1.2.3", "2.0.0")
    assert_equal :major, cmd.classify_update("0.9.9", "1.0.0")
  end

  def test_classify_update_minor
    cmd = Git::Pkgs::Commands::Outdated.new([])

    assert_equal :minor, cmd.classify_update("1.0.0", "1.1.0")
    assert_equal :minor, cmd.classify_update("1.0.0", "1.5.0")
    assert_equal :minor, cmd.classify_update("2.3.4", "2.5.0")
  end

  def test_classify_update_patch
    cmd = Git::Pkgs::Commands::Outdated.new([])

    assert_equal :patch, cmd.classify_update("1.0.0", "1.0.1")
    assert_equal :patch, cmd.classify_update("1.2.3", "1.2.5")
    assert_equal :patch, cmd.classify_update("2.0.0", "2.0.99")
  end

  def test_classify_update_with_v_prefix
    cmd = Git::Pkgs::Commands::Outdated.new([])

    assert_equal :major, cmd.classify_update("v1.0.0", "v2.0.0")
    assert_equal :minor, cmd.classify_update("v1.0.0", "1.1.0")
  end

  def test_classify_update_invalid_format
    cmd = Git::Pkgs::Commands::Outdated.new([])

    assert_nil cmd.classify_update("abc", "def")
    assert_nil cmd.classify_update("", "1.0.0")
  end

  def test_classify_update_downgrade_returns_nil
    cmd = Git::Pkgs::Commands::Outdated.new([])

    assert_nil cmd.classify_update("2.0.0", "1.0.0")
    assert_nil cmd.classify_update("1.5.0", "1.4.0")
    assert_nil cmd.classify_update("1.0.5", "1.0.4")
    assert_nil cmd.classify_update("2.0.0", "1.5.0")
  end

  def test_classify_update_same_version_returns_nil
    cmd = Git::Pkgs::Commands::Outdated.new([])

    assert_nil cmd.classify_update("1.0.0", "1.0.0")
  end

  def test_parse_version
    cmd = Git::Pkgs::Commands::Outdated.new([])

    assert_equal [1, 2, 3], cmd.parse_version("1.2.3")
    assert_equal [1, 0, 0], cmd.parse_version("1")
    assert_equal [1, 2, 0], cmd.parse_version("1.2")
    assert_equal [1, 0, 0], cmd.parse_version("v1.0.0")
  end

  def test_outdated_stateless_with_lockfile
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/lodash": {
            "version": "4.17.15"
          },
          "node_modules/express": {
            "version": "4.18.0"
          }
        }
      }
    JSON
    commit("Add package-lock.json")

    # Stub the ecosystems API
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_return(
        status: 200,
        body: [
          {
            "purl" => "pkg:npm/lodash",
            "latest_release_number" => "4.17.21"
          },
          {
            "purl" => "pkg:npm/express",
            "latest_release_number" => "4.18.0"
          }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Outdated.new(["--stateless"]).run
      end.first
    end

    assert_match(/lodash/, output)
    assert_match(/4\.17\.15/, output)
    assert_match(/4\.17\.21/, output)
    refute_match(/express.*->/, output) # express is up to date
  end

  def test_outdated_major_only_filter
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/lodash": {
            "version": "3.0.0"
          },
          "node_modules/express": {
            "version": "4.17.0"
          }
        }
      }
    JSON
    commit("Add package-lock.json")

    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_return(
        status: 200,
        body: [
          { "purl" => "pkg:npm/lodash", "latest_release_number" => "4.17.21" },
          { "purl" => "pkg:npm/express", "latest_release_number" => "4.18.0" }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Outdated.new(["--stateless", "--major"]).run
      end.first
    end

    assert_match(/lodash/, output) # major update (3 -> 4)
    refute_match(/express/, output) # minor update, should be filtered
  end

  def test_outdated_json_format
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/lodash": {
            "version": "4.17.15"
          }
        }
      }
    JSON
    commit("Add package-lock.json")

    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_return(
        status: 200,
        body: [{ "purl" => "pkg:npm/lodash", "latest_release_number" => "4.17.21" }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Outdated.new(["--stateless", "-f", "json"]).run
      end.first
    end

    json = JSON.parse(output)
    assert_equal 1, json.size
    assert_equal "lodash", json.first["name"]
    assert_equal "4.17.15", json.first["current_version"]
    assert_equal "4.17.21", json.first["latest_version"]
  end

  def test_outdated_all_up_to_date
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/lodash": {
            "version": "4.17.21"
          }
        }
      }
    JSON
    commit("Add package-lock.json")

    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_return(
        status: 200,
        body: [{ "purl" => "pkg:npm/lodash", "latest_release_number" => "4.17.21" }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Outdated.new(["--stateless"]).run
      end.first
    end

    assert_match(/up to date/, output)
  end

  def test_outdated_at_date
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/lodash": {
            "version": "4.17.15"
          }
        }
      }
    JSON
    commit("Add package-lock.json")

    # Stub the versions API to return version history
    stub_request(:get, %r{packages.ecosyste.ms/api/v1/registries/npmjs.org/packages/lodash/versions})
      .to_return(
        status: 200,
        body: [
          { "number" => "4.17.15", "published_at" => "2019-07-19T00:00:00Z" },
          { "number" => "4.17.19", "published_at" => "2020-07-15T00:00:00Z" },
          { "number" => "4.17.21", "published_at" => "2021-02-20T00:00:00Z" }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Outdated.new(["--stateless", "--at", "2020-08-01"]).run
      end.first
    end

    # Should show 4.17.19 as latest (not 4.17.21 which came later)
    assert_match(/lodash/, output)
    assert_match(/4\.17\.15/, output)
    assert_match(/4\.17\.19/, output)
    refute_match(/4\.17\.21/, output)
  end

  def test_outdated_at_git_ref
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/lodash": {
            "version": "4.17.15"
          }
        }
      }
    JSON
    commit("Add package-lock.json")

    # Create a tag with a known date
    Dir.chdir(@test_dir) do
      system("git tag v1.0")
    end

    # The tag's commit date is "now", so we need versions that span around it
    stub_request(:get, %r{packages.ecosyste.ms/api/v1/registries/npmjs.org/packages/lodash/versions})
      .to_return(
        status: 200,
        body: [
          { "number" => "4.17.15", "published_at" => "2019-07-19T00:00:00Z" },
          { "number" => "4.17.21", "published_at" => "2021-02-20T00:00:00Z" }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Outdated.new(["--stateless", "--at", "v1.0"]).run
      end.first
    end

    # Both versions are before "now", so should show 4.17.21 as latest
    assert_match(/lodash/, output)
    assert_match(/4\.17\.21/, output)
  end

  def test_outdated_at_up_to_date_in_past
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/lodash": {
            "version": "4.17.15"
          }
        }
      }
    JSON
    commit("Add package-lock.json")

    stub_request(:get, %r{packages.ecosyste.ms/api/v1/registries/npmjs.org/packages/lodash/versions})
      .to_return(
        status: 200,
        body: [
          { "number" => "4.17.15", "published_at" => "2019-07-19T00:00:00Z" },
          { "number" => "4.17.21", "published_at" => "2021-02-20T00:00:00Z" }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        # At this date, 4.17.15 was the latest version
        Git::Pkgs::Commands::Outdated.new(["--stateless", "--at", "2020-01-01"]).run
      end.first
    end

    assert_match(/up to date/, output)
  end
end
