# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require "stringio"

class Git::Pkgs::TestVulnsCommand < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("package.json", '{"dependencies": {"lodash": "4.17.0"}}')
    commit("Initial commit")

    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def test_vulns_command_initializes
    # Test that Vulns command class can be instantiated
    vulns = Git::Pkgs::Commands::VulnsCommand.new([])

    assert_instance_of Git::Pkgs::Commands::VulnsCommand, vulns
  end

  def test_cli_runs_vulns_command
    stub_osv_api

    Git::Pkgs.git_dir = @git_dir
    output = capture_stdout do
      Git::Pkgs::CLI.run(["vulns", "--stateless"])
    end

    # Should not output "not yet implemented"
    refute_includes output, "not yet implemented"
  ensure
    Git::Pkgs.git_dir = nil
  end

  def test_vulns_command_runs_scan_by_default
    stub_osv_api

    Git::Pkgs.git_dir = @git_dir
    output = capture_stdout do
      Git::Pkgs::Commands::VulnsCommand.new(["--stateless"]).run
    end

    # Should either show vulnerabilities or no vulnerabilities found
    assert output.include?("No known vulnerabilities found") || output.include?("GHSA")
  ensure
    Git::Pkgs.git_dir = nil
  end

  def test_vulns_subcommand_sync
    stub_osv_api

    Git::Pkgs.git_dir = @git_dir

    # First add a package to the database
    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash"
    )

    output = capture_stdout do
      Git::Pkgs::Commands::VulnsCommand.new(["sync"]).run
    end

    assert_includes output, "Syncing vulnerabilities"
  ensure
    Git::Pkgs.git_dir = nil
  end

  def test_vulns_subcommand_diff_parses_both_refs
    vulns = Git::Pkgs::Commands::VulnsCommand.new(["diff", "abc123", "def456"])
    args = vulns.instance_variable_get(:@args)

    # Both refs should be available in args for VulnsDiff to consume
    assert_includes args, "abc123"
    assert_includes args, "def456"
  end

  def test_vulns_subcommand_log_detected
    vulns = Git::Pkgs::Commands::VulnsCommand.new(["log"])
    subcommand = vulns.instance_variable_get(:@subcommand)

    assert_equal "log", subcommand
  end

  def stub_osv_api
    # Stub the batch query endpoint
    WebMock.stub_request(:post, "https://api.osv.dev/v1/querybatch")
      .to_return(
        status: 200,
        body: '{"results": [{"vulns": [{"id": "GHSA-test", "modified": "2024-01-01"}]}]}'
      )

    # Stub the individual vulnerability endpoint
    WebMock.stub_request(:get, %r{https://api\.osv\.dev/v1/vulns/.*})
      .to_return(
        status: 200,
        body: JSON.generate({
          id: "GHSA-test",
          summary: "Test vulnerability",
          affected: [{
            package: { name: "lodash", ecosystem: "npm" },
            ranges: [{ events: [{ introduced: "0" }, { fixed: "4.17.21" }] }]
          }]
        })
      )
  end
end

class Git::Pkgs::TestVulnsExposure < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("package.json", '{"dependencies": {"lodash": "4.17.0"}}')
    commit("Initial commit")

    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema

    # Initialize database with commits
    Git::Pkgs.git_dir = @git_dir
    capture_stdout { Git::Pkgs::Commands::Init.new(["--no-hooks", "--force"]).run }
    Git::Pkgs.git_dir = nil
  end

  def teardown
    Git::Pkgs.git_dir = nil
    cleanup_test_repo
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def test_exposure_output_does_not_use_invalid_color
    stub_osv_api

    # Create a vulnerability that affects our package
    Git::Pkgs::Models::Vulnerability.create(
      id: "GHSA-test",
      severity: nil,  # Unknown severity triggers the :default color bug
      fetched_at: Time.now
    )

    Git::Pkgs::Models::VulnerabilityPackage.create(
      vulnerability_id: "GHSA-test",
      ecosystem: "npm",
      package_name: "lodash",
      affected_versions: "<4.17.21"
    )

    Git::Pkgs.git_dir = @git_dir
    # This should not raise NoMethodError for Color.default
    output = capture_stdout do
      Git::Pkgs::Commands::Vulns::Exposure.new([]).run
    end

    assert output
  ensure
    Git::Pkgs.git_dir = nil
  end

  def stub_osv_api
    WebMock.stub_request(:post, "https://api.osv.dev/v1/querybatch")
      .to_return(status: 200, body: '{"results": [{"vulns": []}]}')
  end
end

class Git::Pkgs::TestVulnsBase < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
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

  def test_more_specific_version_prefers_actual_versions
    test_class = Class.new do
      include Git::Pkgs::Commands::Vulns::Base
      def initialize
        @options = {}
      end
    end

    handler = test_class.new

    # Actual version preferred over constraint
    assert handler.more_specific_version?("1.2.3", ">= 0")
    assert handler.more_specific_version?("4.17.21", ">= 1.0")

    # Constraint not preferred over actual version
    refute handler.more_specific_version?(">= 0", "1.2.3")
    refute handler.more_specific_version?(">= 1.0", "4.17.21")

    # Two actual versions - neither preferred
    refute handler.more_specific_version?("1.2.3", "1.2.4")

    # Two constraints - neither preferred
    refute handler.more_specific_version?(">= 1.0", ">= 0")
  end
end

class Git::Pkgs::TestVulnsScan < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("package.json", '{"dependencies": {"lodash": "4.17.0"}}')
    commit("Initial commit")

    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def test_scan_stateless_mode
    stub_osv_api

    Git::Pkgs.git_dir = @git_dir
    output = capture_stdout do
      Git::Pkgs::Commands::Vulns::Scan.new(["--stateless"]).run
    end

    # Should complete without error
    assert output
  ensure
    Git::Pkgs.git_dir = nil
  end

  def test_scan_with_vulnerabilities_found
    stub_osv_with_matching_vuln

    Git::Pkgs.git_dir = @git_dir
    output = capture_stdout do
      Git::Pkgs::Commands::Vulns::Scan.new(["--stateless"]).run
    end

    assert_includes output, "GHSA-test"
  ensure
    Git::Pkgs.git_dir = nil
  end

  def stub_osv_api
    WebMock.stub_request(:post, "https://api.osv.dev/v1/querybatch")
      .to_return(status: 200, body: '{"results": [{"vulns": []}]}')
  end

  def stub_osv_with_matching_vuln
    WebMock.stub_request(:post, "https://api.osv.dev/v1/querybatch")
      .to_return(
        status: 200,
        body: '{"results": [{"vulns": [{"id": "GHSA-test", "modified": "2024-01-01"}]}]}'
      )

    WebMock.stub_request(:get, "https://api.osv.dev/v1/vulns/GHSA-test")
      .to_return(
        status: 200,
        body: JSON.generate({
          id: "GHSA-test",
          summary: "Prototype pollution in lodash",
          severity: [{ type: "CVSS_V3", score: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" }],
          affected: [{
            package: { name: "lodash", ecosystem: "npm" },
            ranges: [{ events: [{ introduced: "0" }, { fixed: "4.17.21" }] }],
            database_specific: { severity: "HIGH" }
          }]
        })
      )
  end

  def test_scan_sarif_output_format
    stub_osv_with_matching_vuln

    Git::Pkgs.git_dir = @git_dir
    output = capture_stdout do
      Git::Pkgs::Commands::Vulns::Scan.new(["--stateless", "-f", "sarif"]).run
    end

    sarif = JSON.parse(output)
    assert_equal "2.1.0", sarif["version"]
    assert_equal 1, sarif["runs"].length

    run = sarif["runs"][0]
    assert_equal "git-pkgs", run["tool"]["driver"]["name"]
    assert run["tool"]["driver"]["rules"].any? { |r| r["id"] == "GHSA-test" }
    assert run["results"].any? { |r| r["ruleId"] == "GHSA-test" }
    assert_equal "error", run["results"][0]["level"]

    # Validate against SARIF 2.1.0 schema
    require "json_schemer"
    schema_path = File.join(File.dirname(__FILE__), "../../fixtures/sarif-schema-2.1.0.json")
    schema = JSONSchemer.schema(Pathname.new(schema_path))
    errors = schema.validate(sarif).to_a
    assert_empty errors, "SARIF schema validation failed: #{errors.map { |e| e["error"] }.join(", ")}"
  ensure
    Git::Pkgs.git_dir = nil
  end
end

class Git::Pkgs::TestVulnsDiff < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo

    add_file("package.json", '{"dependencies": {"lodash": "4.17.0"}}')
    commit("Initial commit")
    @first_sha = `cd #{@test_dir} && git rev-parse HEAD`.strip

    add_file("package.json", '{"dependencies": {"lodash": "4.17.21"}}')
    commit("Update lodash")
    @second_sha = `cd #{@test_dir} && git rev-parse HEAD`.strip

    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema

    # Initialize database with commits
    Git::Pkgs.git_dir = @git_dir
    capture_stdout { Git::Pkgs::Commands::Init.new(["--no-hooks", "--force"]).run }
    Git::Pkgs.git_dir = nil
  end

  def teardown
    Git::Pkgs.git_dir = nil
    cleanup_test_repo
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def test_diff_receives_both_refs
    stub_osv_api

    Git::Pkgs.git_dir = @git_dir
    output = capture_stdout do
      Git::Pkgs::Commands::Vulns::Diff.new([@first_sha[0, 7], @second_sha[0, 7]]).run
    end

    # Should complete without error (may show no changes)
    assert output
  ensure
    Git::Pkgs.git_dir = nil
  end

  def stub_osv_api
    WebMock.stub_request(:post, "https://api.osv.dev/v1/querybatch")
      .to_return(status: 200, body: '{"results": [{"vulns": []}]}')
  end
end

class Git::Pkgs::TestVulnsSync < Minitest::Test
  include TestHelpers

  def setup
    Git::Pkgs::Database.disconnect
    create_test_repo
    add_file("package.json", '{"dependencies": {"lodash": "4.17.0"}}')
    commit("Initial commit")

    @git_dir = File.join(@test_dir, ".git")
    Git::Pkgs::Database.connect(@git_dir)
    Git::Pkgs::Database.create_schema
  end

  def teardown
    cleanup_test_repo
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def test_sync_fetches_full_vulnerability_details
    # Create a package that needs sync
    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash"
    )

    # Stub batch query to return minimal data (just id)
    WebMock.stub_request(:post, "https://api.osv.dev/v1/querybatch")
      .to_return(
        status: 200,
        body: '{"results": [{"vulns": [{"id": "GHSA-test", "modified": "2024-01-01"}]}]}'
      )

    # Stub individual vuln fetch to return full data with affected packages
    WebMock.stub_request(:get, "https://api.osv.dev/v1/vulns/GHSA-test")
      .to_return(
        status: 200,
        body: JSON.generate({
          id: "GHSA-test",
          summary: "Test vulnerability",
          affected: [{
            package: { name: "lodash", ecosystem: "npm" },
            ranges: [{ events: [{ introduced: "0" }, { fixed: "4.17.21" }] }]
          }]
        })
      )

    Git::Pkgs.git_dir = @git_dir
    capture_stdout do
      Git::Pkgs::Commands::Vulns::Sync.new([]).run
    end

    # Verify that VulnerabilityPackage records were created
    vuln_pkgs = Git::Pkgs::Models::VulnerabilityPackage.where(vulnerability_id: "GHSA-test")
    assert_equal 1, vuln_pkgs.count
    assert_equal "lodash", vuln_pkgs.first.package_name
  ensure
    Git::Pkgs.git_dir = nil
  end
end

class Git::Pkgs::TestManifestLockfilePairing < Minitest::Test
  def test_pair_manifests_with_lockfiles_prefers_lockfile
    deps = [
      { manifest_path: "Gemfile", manifest_kind: "manifest", ecosystem: "rubygems", name: "rails", requirement: ">= 0" },
      { manifest_path: "Gemfile.lock", manifest_kind: "lockfile", ecosystem: "rubygems", name: "rails", requirement: "7.0.0" }
    ]

    result = Git::Pkgs::Analyzer.pair_manifests_with_lockfiles(deps)

    assert_equal 1, result.size
    assert_equal "7.0.0", result.first[:requirement]
    assert_equal "lockfile", result.first[:manifest_kind]
  end

  def test_pair_manifests_with_lockfiles_falls_back_to_manifest
    deps = [
      { manifest_path: "Gemfile", manifest_kind: "manifest", ecosystem: "rubygems", name: "rails", requirement: "~> 7.0" }
    ]

    result = Git::Pkgs::Analyzer.pair_manifests_with_lockfiles(deps)

    assert_equal 1, result.size
    assert_equal "~> 7.0", result.first[:requirement]
    assert_equal "manifest", result.first[:manifest_kind]
  end

  def test_pair_manifests_with_lockfiles_groups_by_directory
    deps = [
      { manifest_path: "Gemfile", manifest_kind: "manifest", ecosystem: "rubygems", name: "rails", requirement: ">= 0" },
      { manifest_path: "Gemfile.lock", manifest_kind: "lockfile", ecosystem: "rubygems", name: "rails", requirement: "7.0.0" },
      { manifest_path: "vendor/Gemfile", manifest_kind: "manifest", ecosystem: "rubygems", name: "rails", requirement: ">= 6.0" },
      { manifest_path: "vendor/Gemfile.lock", manifest_kind: "lockfile", ecosystem: "rubygems", name: "rails", requirement: "6.1.0" }
    ]

    result = Git::Pkgs::Analyzer.pair_manifests_with_lockfiles(deps)

    assert_equal 2, result.size
    versions = result.map { |d| d[:requirement] }.sort
    assert_equal ["6.1.0", "7.0.0"], versions
  end

  def test_pair_manifests_with_lockfiles_handles_multiple_packages
    deps = [
      { manifest_path: "Gemfile", manifest_kind: "manifest", ecosystem: "rubygems", name: "rails", requirement: ">= 0" },
      { manifest_path: "Gemfile.lock", manifest_kind: "lockfile", ecosystem: "rubygems", name: "rails", requirement: "7.0.0" },
      { manifest_path: "Gemfile", manifest_kind: "manifest", ecosystem: "rubygems", name: "puma", requirement: ">= 0" },
      { manifest_path: "Gemfile.lock", manifest_kind: "lockfile", ecosystem: "rubygems", name: "puma", requirement: "6.0.0" }
    ]

    result = Git::Pkgs::Analyzer.pair_manifests_with_lockfiles(deps)

    assert_equal 2, result.size
    by_name = result.group_by { |d| d[:name] }
    assert_equal "7.0.0", by_name["rails"].first[:requirement]
    assert_equal "6.0.0", by_name["puma"].first[:requirement]
  end

  def test_lockfile_dependencies_filter
    deps = [
      { manifest_path: "Gemfile", manifest_kind: "manifest", ecosystem: "rubygems", name: "rails", requirement: ">= 0" },
      { manifest_path: "Gemfile.lock", manifest_kind: "lockfile", ecosystem: "rubygems", name: "rails", requirement: "7.0.0" },
      { manifest_path: "Gemfile", manifest_kind: "manifest", ecosystem: "rubygems", name: "puma", requirement: "~> 6.0" }
    ]

    result = Git::Pkgs::Analyzer.lockfile_dependencies(deps)

    assert_equal 1, result.size
    assert_equal "rails", result.first[:name]
    assert_equal "7.0.0", result.first[:requirement]
  end
end
