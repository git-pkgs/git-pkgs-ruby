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
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/lookup")
      .with(body: { purl: ["pkg:gem/rails", "pkg:npm/lodash"] }.to_json)
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
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/lookup")
      .with { |req| JSON.parse(req.body)["purl"].size == 100 }
      .to_return(
        status: 200,
        body: (1..100).map { |i| { "purl" => "pkg:npm/package-#{i}", "name" => "package-#{i}" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    # Second batch of 50
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/lookup")
      .with { |req| JSON.parse(req.body)["purl"].size == 50 }
      .to_return(
        status: 200,
        body: (101..150).map { |i| { "purl" => "pkg:npm/package-#{i}", "name" => "package-#{i}" } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    results = @client.bulk_lookup(purls)

    assert_equal 150, results.size
  end

  def test_lookup_single_package
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/lookup")
      .with(body: { purl: ["pkg:gem/rails"] }.to_json)
      .to_return(
        status: 200,
        body: [{ "purl" => "pkg:gem/rails", "latest_release_number" => "7.1.0" }].to_json,
        headers: { "Content-Type" => "application/json" }
      )

    result = @client.lookup("pkg:gem/rails")

    assert_equal "7.1.0", result["latest_release_number"]
  end

  def test_lookup_returns_nil_for_not_found
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/lookup")
      .to_return(status: 404)

    result = @client.lookup("pkg:gem/nonexistent")

    assert_nil result
  end

  def test_api_error_on_failure
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/lookup")
      .to_return(status: 500, body: "Internal Server Error")

    assert_raises(Git::Pkgs::EcosystemsClient::ApiError) do
      @client.bulk_lookup(["pkg:gem/rails"])
    end
  end

  def test_api_error_on_timeout
    stub_request(:post, "https://packages.ecosyste.ms/api/v1/packages/lookup")
      .to_timeout

    assert_raises(Git::Pkgs::EcosystemsClient::ApiError) do
      @client.bulk_lookup(["pkg:gem/rails"])
    end
  end
end
