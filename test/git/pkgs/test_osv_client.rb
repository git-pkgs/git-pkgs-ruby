# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class Git::Pkgs::TestOsvClient < Minitest::Test
  def setup
    @client = Git::Pkgs::OsvClient.new
    WebMock.disable_net_connect!
  end

  def teardown
    WebMock.allow_net_connect!
  end

  def test_query_returns_vulnerabilities
    stub_request(:post, "https://api.osv.dev/v1/query")
      .with(body: {
        package: { name: "lodash", ecosystem: "npm" },
        version: "4.17.15"
      }.to_json)
      .to_return(
        status: 200,
        body: {
          vulns: [
            { id: "GHSA-1234", summary: "Test vulnerability" }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    vulns = @client.query(ecosystem: "npm", name: "lodash", version: "4.17.15")

    assert_equal 1, vulns.size
    assert_equal "GHSA-1234", vulns.first["id"]
  end

  def test_query_handles_pagination
    stub_request(:post, "https://api.osv.dev/v1/query")
      .with(body: {
        package: { name: "lodash", ecosystem: "npm" },
        version: "4.17.15"
      }.to_json)
      .to_return(
        status: 200,
        body: {
          vulns: [{ id: "GHSA-1" }],
          next_page_token: "token123"
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    stub_request(:post, "https://api.osv.dev/v1/query")
      .with(body: {
        package: { name: "lodash", ecosystem: "npm" },
        version: "4.17.15",
        page_token: "token123"
      }.to_json)
      .to_return(
        status: 200,
        body: {
          vulns: [{ id: "GHSA-2" }]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    vulns = @client.query(ecosystem: "npm", name: "lodash", version: "4.17.15")

    assert_equal 2, vulns.size
    assert_equal "GHSA-1", vulns[0]["id"]
    assert_equal "GHSA-2", vulns[1]["id"]
  end

  def test_query_returns_empty_array_when_no_vulns
    stub_request(:post, "https://api.osv.dev/v1/query")
      .to_return(
        status: 200,
        body: { vulns: nil }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    vulns = @client.query(ecosystem: "npm", name: "safe-package", version: "1.0.0")

    assert_equal [], vulns
  end

  def test_query_batch_returns_results_per_package
    stub_request(:post, "https://api.osv.dev/v1/querybatch")
      .to_return(
        status: 200,
        body: {
          results: [
            { vulns: [{ id: "CVE-1" }] },
            { vulns: [] },
            { vulns: [{ id: "CVE-2" }, { id: "CVE-3" }] }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    packages = [
      { ecosystem: "npm", name: "lodash", version: "4.17.15" },
      { ecosystem: "npm", name: "safe", version: "1.0.0" },
      { ecosystem: "RubyGems", name: "nokogiri", version: "1.10.0" }
    ]

    results = @client.query_batch(packages)

    assert_equal 3, results.size
    assert_equal 1, results[0].size
    assert_equal 0, results[1].size
    assert_equal 2, results[2].size
  end

  def test_query_batch_empty_input
    results = @client.query_batch([])
    assert_equal [], results
  end

  def test_get_vulnerability_by_id
    stub_request(:get, "https://api.osv.dev/v1/vulns/CVE-2024-1234")
      .to_return(
        status: 200,
        body: {
          id: "CVE-2024-1234",
          summary: "Test CVE",
          details: "Detailed description"
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    vuln = @client.get_vulnerability("CVE-2024-1234")

    assert_equal "CVE-2024-1234", vuln["id"]
    assert_equal "Test CVE", vuln["summary"]
  end

  def test_api_error_on_failure
    stub_request(:post, "https://api.osv.dev/v1/query")
      .to_return(status: 500, body: "Internal Server Error")

    assert_raises(Git::Pkgs::OsvClient::ApiError) do
      @client.query(ecosystem: "npm", name: "lodash", version: "1.0.0")
    end
  end

  def test_api_error_on_timeout
    stub_request(:post, "https://api.osv.dev/v1/query")
      .to_timeout

    assert_raises(Git::Pkgs::OsvClient::ApiError) do
      @client.query(ecosystem: "npm", name: "lodash", version: "1.0.0")
    end
  end
end
