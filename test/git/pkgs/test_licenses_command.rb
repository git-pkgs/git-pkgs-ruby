# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class Git::Pkgs::TestLicensesCommand < Minitest::Test
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

  def test_check_violation_permissive_allows_mit
    cmd = Git::Pkgs::Commands::Licenses.new(["--permissive"])

    # Override options to test directly
    cmd.instance_variable_set(:@options, { permissive: true, allow: [], deny: [] })

    assert_nil cmd.check_violation("MIT")
    assert_nil cmd.check_violation("Apache-2.0")
    assert_nil cmd.check_violation("BSD-3-Clause")
  end

  def test_check_violation_permissive_flags_gpl
    cmd = Git::Pkgs::Commands::Licenses.new([])
    cmd.instance_variable_set(:@options, { permissive: true, allow: [], deny: [] })

    assert_equal "copyleft", cmd.check_violation("GPL-3.0")
    assert_equal "copyleft", cmd.check_violation("AGPL-3.0")
    assert_equal "copyleft", cmd.check_violation("LGPL-2.1")
  end

  def test_check_violation_deny_list
    cmd = Git::Pkgs::Commands::Licenses.new([])
    cmd.instance_variable_set(:@options, { deny: ["GPL-3.0", "AGPL-3.0"], allow: [] })

    assert_equal "denied", cmd.check_violation("GPL-3.0")
    assert_equal "denied", cmd.check_violation("AGPL-3.0")
    assert_nil cmd.check_violation("MIT")
  end

  def test_check_violation_allow_list
    cmd = Git::Pkgs::Commands::Licenses.new([])
    cmd.instance_variable_set(:@options, { allow: ["MIT", "Apache-2.0"], deny: [] })

    assert_nil cmd.check_violation("MIT")
    assert_nil cmd.check_violation("Apache-2.0")
    assert_equal "not-allowed", cmd.check_violation("GPL-3.0")
    assert_equal "not-allowed", cmd.check_violation("BSD-3-Clause")
  end

  def test_check_violation_unknown_license
    cmd = Git::Pkgs::Commands::Licenses.new([])
    cmd.instance_variable_set(:@options, { unknown: true, allow: [], deny: [] })

    assert_equal "unknown", cmd.check_violation(nil)
    assert_equal "unknown", cmd.check_violation("")
    assert_nil cmd.check_violation("MIT")
  end

  def test_check_violation_copyleft_flag
    cmd = Git::Pkgs::Commands::Licenses.new([])
    cmd.instance_variable_set(:@options, { copyleft: true, allow: [], deny: [] })

    assert_equal "copyleft", cmd.check_violation("GPL-3.0")
    assert_equal "copyleft", cmd.check_violation("MPL-2.0")
    assert_nil cmd.check_violation("MIT")
  end

  def test_licenses_stateless_basic
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/lodash": {
            "version": "4.17.21"
          },
          "node_modules/express": {
            "version": "4.18.0"
          }
        }
      }
    JSON
    commit("Add package-lock.json")

    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_return(
        status: 200,
        body: [
          { "purl" => "pkg:npm/lodash", "normalized_licenses" => ["MIT"] },
          { "purl" => "pkg:npm/express", "normalized_licenses" => ["MIT"] }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Licenses.new(["--stateless"]).run
      end.first
    end

    assert_match(/lodash/, output)
    assert_match(/express/, output)
    assert_match(/MIT/, output)
  end

  def test_licenses_json_format
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
        body: [{ "purl" => "pkg:npm/lodash", "normalized_licenses" => ["MIT"] }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Licenses.new(["--stateless", "-f", "json"]).run
      end.first
    end

    json = JSON.parse(output)
    assert json["packages"]
    assert json["summary"]
    assert_equal 1, json["summary"]["total"]
  end

  def test_licenses_csv_format
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
        body: [{ "purl" => "pkg:npm/lodash", "normalized_licenses" => ["MIT"] }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Licenses.new(["--stateless", "-f", "csv"]).run
      end.first
    end

    lines = output.strip.split("\n")
    assert_equal "name,ecosystem,version,license,violation", lines.first
    assert_match(/lodash,npm,4\.17\.21,MIT/, lines[1])
  end

  def test_licenses_exits_nonzero_on_violation
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/gpl-package": {
            "version": "1.0.0"
          }
        }
      }
    JSON
    commit("Add package-lock.json")

    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_return(
        status: 200,
        body: [{ "purl" => "pkg:npm/gpl-package", "normalized_licenses" => ["GPL-3.0"] }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    assert_raises(SystemExit) do
      Dir.chdir(@test_dir) do
        capture_io do
          Git::Pkgs::Commands::Licenses.new(["--stateless", "--permissive"]).run
        end
      end
    end
  end

  def test_licenses_grouped_output
    add_file("package-lock.json", <<~JSON)
      {
        "name": "test-project",
        "lockfileVersion": 2,
        "packages": {
          "node_modules/lodash": { "version": "4.17.21" },
          "node_modules/express": { "version": "4.18.0" },
          "node_modules/request": { "version": "2.88.0" }
        }
      }
    JSON
    commit("Add package-lock.json")

    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_return(
        status: 200,
        body: [
          { "purl" => "pkg:npm/lodash", "normalized_licenses" => ["MIT"] },
          { "purl" => "pkg:npm/express", "normalized_licenses" => ["MIT"] },
          { "purl" => "pkg:npm/request", "normalized_licenses" => ["Apache-2.0"] }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    output = Dir.chdir(@test_dir) do
      capture_io do
        Git::Pkgs::Commands::Licenses.new(["--stateless", "--group"]).run
      end.first
    end

    # Should show MIT (2) and Apache-2.0 (1) as groups
    assert_match(/MIT \(2\)/, output)
    assert_match(/Apache-2\.0 \(1\)/, output)
  end
end
