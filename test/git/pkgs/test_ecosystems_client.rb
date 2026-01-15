# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class Git::Pkgs::TestEcosystemsClient < Minitest::Test
  def setup
    @client = Git::Pkgs::EcosystemsClient.new
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.allow_net_connect!
  end

  def test_bulk_lookup_returns_packages_by_purl
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .with(body: { purls: ["pkg:gem/rails", "pkg:npm/lodash"] }.to_json)
      .to_return(
        status: 200,
        body: [
          {
            "purl" => "pkg:gem/rails",
            "name" => "rails",
            "ecosystem" => "rubygems",
            "latest_release_number" => "7.1.0",
            "normalized_licenses" => ["MIT"]
          },
          {
            "purl" => "pkg:npm/lodash",
            "name" => "lodash",
            "ecosystem" => "npm",
            "latest_release_number" => "4.17.21",
            "normalized_licenses" => ["MIT"]
          }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    results = @client.bulk_lookup(["pkg:gem/rails", "pkg:npm/lodash"])

    assert_equal 2, results.size
    assert_equal "7.1.0", results["pkg:gem/rails"]["latest_release_number"]
    assert_equal "4.17.21", results["pkg:npm/lodash"]["latest_release_number"]
  end

  def test_bulk_lookup_empty_input
    results = @client.bulk_lookup([])
    assert_equal({}, results)
  end

  def test_bulk_lookup_batches_large_requests
    # Create 150 purls to trigger batching (max 100 per request)
    purls = (1..150).map { |i| "pkg:npm/package-#{i}" }

    # First batch of 100
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .with { |req| JSON.parse(req.body)["purls"].size == 100 }
      .to_return(
        status: 200,
        body: (1..100).map { |i| { "purl" => "pkg:npm/package-#{i}", "name" => "package-#{i}" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    # Second batch of 50
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .with { |req| JSON.parse(req.body)["purls"].size == 50 }
      .to_return(
        status: 200,
        body: (101..150).map { |i| { "purl" => "pkg:npm/package-#{i}", "name" => "package-#{i}" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    results = @client.bulk_lookup(purls)

    assert_equal 150, results.size
  end

  def test_lookup_single_package
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .with(body: { purls: ["pkg:gem/rails"] }.to_json)
      .to_return(
        status: 200,
        body: [{ "purl" => "pkg:gem/rails", "latest_release_number" => "7.1.0" }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @client.lookup("pkg:gem/rails")

    assert_equal "7.1.0", result["latest_release_number"]
  end

  def test_lookup_returns_nil_for_not_found
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_return(status: 404)

    result = @client.lookup("pkg:gem/nonexistent")

    assert_nil result
  end

  def test_api_error_on_failure
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_return(status: 500, body: "Internal Server Error")

    assert_raises(Git::Pkgs::EcosystemsClient::ApiError) do
      @client.bulk_lookup(["pkg:gem/rails"])
    end
  end

  def test_api_error_on_timeout
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/bulk_lookup")
      .to_timeout

    assert_raises(Git::Pkgs::EcosystemsClient::ApiError) do
      @client.bulk_lookup(["pkg:gem/rails"])
    end
  end

  def test_lookup_all_versions
    stub_request(:get, "https://packages.ecosyste.ms/api/v1/registries/rubygems.org/packages/rails/versions?page=1&per_page=100")
      .to_return(
        status: 200,
        body: [
          { "number" => "7.0.0", "published_at" => "2021-12-15T00:00:00Z" },
          { "number" => "7.1.0", "published_at" => "2023-10-05T00:00:00Z" }
        ].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    versions = @client.lookup_all_versions("pkg:gem/rails")

    assert_equal 2, versions.size
    assert_equal "7.0.0", versions[0]["number"]
    assert_equal "7.1.0", versions[1]["number"]
  end

  def test_lookup_all_versions_paginates
    stub_request(:get, "https://packages.ecosyste.ms/api/v1/registries/rubygems.org/packages/rails/versions?page=1&per_page=100")
      .to_return(
        status: 200,
        body: (1..100).map { |i| { "number" => "1.0.#{i}" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:get, "https://packages.ecosyste.ms/api/v1/registries/rubygems.org/packages/rails/versions?page=2&per_page=100")
      .to_return(
        status: 200,
        body: [{ "number" => "2.0.0" }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    versions = @client.lookup_all_versions("pkg:gem/rails")

    assert_equal 101, versions.size
  end

  def test_lookup_all_versions_returns_nil_for_not_found
    stub_request(:get, %r{packages.ecosyste.ms/api/v1/registries/rubygems.org/packages/nonexistent/versions})
      .to_return(status: 404)

    result = @client.lookup_all_versions("pkg:gem/nonexistent")

    assert_nil result
  end

  def test_bulk_lookup_all_versions
    stub_request(:get, %r{packages.ecosyste.ms/api/v1/registries/rubygems.org/packages/rails/versions})
      .to_return(
        status: 200,
        body: [{ "number" => "7.1.0", "published_at" => "2023-10-05T00:00:00Z" }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:get, %r{packages.ecosyste.ms/api/v1/registries/npmjs.org/packages/lodash/versions})
      .to_return(
        status: 200,
        body: [{ "number" => "4.17.21", "published_at" => "2021-02-20T00:00:00Z" }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    results = @client.bulk_lookup_all_versions(["pkg:gem/rails", "pkg:npm/lodash"])

    assert_equal 2, results.size
    assert_equal 1, results["pkg:gem/rails"].size
    assert_equal 1, results["pkg:npm/lodash"].size
  end
end
