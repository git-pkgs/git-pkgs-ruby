# frozen_string_literal: true

require "test_helper"

class Git::Pkgs::TestPackage < Minitest::Test
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

  def test_create_package
    pkg = Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash"
    )

    assert_equal "pkg:npm/lodash", pkg.purl
    assert_equal "npm", pkg.ecosystem
    assert_equal "lodash", pkg.name
  end

  def test_unique_purl_constraint
    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash"
    )

    assert_raises(Sequel::UniqueConstraintViolation) do
      Git::Pkgs::Models::Package.create(
        purl: "pkg:npm/lodash",
        ecosystem: "npm",
        name: "lodash"
      )
    end
  end

  def test_generate_purl
    assert_equal "pkg:npm/lodash", Git::Pkgs::Models::Package.generate_purl("npm", "lodash")
    assert_equal "pkg:gem/rails", Git::Pkgs::Models::Package.generate_purl("rubygems", "rails")
    assert_equal "pkg:pypi/requests", Git::Pkgs::Models::Package.generate_purl("pypi", "requests")
    assert_equal "pkg:cargo/serde", Git::Pkgs::Models::Package.generate_purl("cargo", "serde")
  end

  def test_generate_purl_unsupported_ecosystem
    assert_nil Git::Pkgs::Models::Package.generate_purl("unknown", "package")
  end

  def test_find_or_create_by_purl
    pkg1 = Git::Pkgs::Models::Package.find_or_create_by_purl(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash"
    )

    pkg2 = Git::Pkgs::Models::Package.find_or_create_by_purl(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash"
    )

    assert_equal pkg1.id, pkg2.id
    assert_equal 1, Git::Pkgs::Models::Package.count
  end

  def test_needs_vuln_sync_when_never_synced
    pkg = Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash",
      vulns_synced_at: nil
    )

    assert pkg.needs_vuln_sync?
  end

  def test_needs_vuln_sync_when_stale
    pkg = Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash",
      vulns_synced_at: Time.now - 100_000
    )

    assert pkg.needs_vuln_sync?
  end

  def test_needs_vuln_sync_when_fresh
    pkg = Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash",
      vulns_synced_at: Time.now
    )

    refute pkg.needs_vuln_sync?
  end

  def test_mark_vulns_synced
    pkg = Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash",
      vulns_synced_at: nil
    )

    assert pkg.needs_vuln_sync?
    pkg.mark_vulns_synced
    pkg.refresh

    refute pkg.needs_vuln_sync?
    assert_in_delta Time.now, pkg.vulns_synced_at, 1
  end

  def test_needs_vuln_sync_scope
    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/stale",
      ecosystem: "npm",
      name: "stale",
      vulns_synced_at: Time.now - 100_000
    )

    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/fresh",
      ecosystem: "npm",
      name: "fresh",
      vulns_synced_at: Time.now
    )

    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/never",
      ecosystem: "npm",
      name: "never",
      vulns_synced_at: nil
    )

    needs_sync = Git::Pkgs::Models::Package.needs_vuln_sync
    assert_equal 2, needs_sync.count
    purls = needs_sync.map(&:purl).sort
    assert_equal ["pkg:npm/never", "pkg:npm/stale"], purls
  end

  def test_synced_scope
    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/stale",
      ecosystem: "npm",
      name: "stale",
      vulns_synced_at: Time.now - 100_000
    )

    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/fresh",
      ecosystem: "npm",
      name: "fresh",
      vulns_synced_at: Time.now
    )

    synced = Git::Pkgs::Models::Package.synced
    assert_equal 1, synced.count
    assert_equal "pkg:npm/fresh", synced.first.purl
  end

  def test_by_ecosystem_scope
    Git::Pkgs::Models::Package.create(purl: "pkg:npm/lodash", ecosystem: "npm", name: "lodash")
    Git::Pkgs::Models::Package.create(purl: "pkg:gem/rails", ecosystem: "rubygems", name: "rails")
    Git::Pkgs::Models::Package.create(purl: "pkg:npm/express", ecosystem: "npm", name: "express")

    npm_pkgs = Git::Pkgs::Models::Package.by_ecosystem("npm")
    assert_equal 2, npm_pkgs.count

    gem_pkgs = Git::Pkgs::Models::Package.by_ecosystem("rubygems")
    assert_equal 1, gem_pkgs.count
    assert_equal "rails", gem_pkgs.first.name
  end

  def test_needs_enrichment_when_never_enriched
    pkg = Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash",
      enriched_at: nil
    )

    assert pkg.needs_enrichment?
  end

  def test_needs_enrichment_when_stale
    pkg = Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash",
      enriched_at: Time.now - 100_000
    )

    assert pkg.needs_enrichment?
  end

  def test_needs_enrichment_when_fresh
    pkg = Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash",
      enriched_at: Time.now
    )

    refute pkg.needs_enrichment?
  end

  def test_enrich_from_api
    pkg = Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/lodash",
      ecosystem: "npm",
      name: "lodash"
    )

    api_data = {
      "latest_release_number" => "4.17.21",
      "normalized_licenses" => ["MIT"],
      "description" => "Lodash modular utilities",
      "homepage" => "https://lodash.com/",
      "repository_url" => "https://github.com/lodash/lodash"
    }

    pkg.enrich_from_api(api_data)
    pkg.refresh

    assert_equal "4.17.21", pkg.latest_version
    assert_equal "MIT", pkg.license
    assert_equal "Lodash modular utilities", pkg.description
    assert_equal "https://lodash.com/", pkg.homepage
    assert_equal "https://github.com/lodash/lodash", pkg.repository_url
    refute_nil pkg.enriched_at
  end

  def test_needs_enrichment_scope
    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/stale",
      ecosystem: "npm",
      name: "stale",
      enriched_at: Time.now - 100_000
    )

    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/fresh",
      ecosystem: "npm",
      name: "fresh",
      enriched_at: Time.now
    )

    Git::Pkgs::Models::Package.create(
      purl: "pkg:npm/never",
      ecosystem: "npm",
      name: "never",
      enriched_at: nil
    )

    needs_enrichment = Git::Pkgs::Models::Package.needs_enrichment
    assert_equal 2, needs_enrichment.count
    purls = needs_enrichment.map(&:purl).sort
    assert_equal ["pkg:npm/never", "pkg:npm/stale"], purls
  end
end
