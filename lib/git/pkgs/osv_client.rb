# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Git
  module Pkgs
    # Client for the OSV (Open Source Vulnerabilities) API.
    # https://google.github.io/osv.dev/api/
    class OsvClient
      API_BASE = "https://api.osv.dev/v1"
      BATCH_SIZE = 1000 # Max queries per batch request

      class Error < StandardError; end
      class ApiError < Error; end

      def initialize
        @http_clients = {}
      end

      # Query vulnerabilities for a single package version.
      #
      # @param ecosystem [String] OSV ecosystem name (e.g., "RubyGems")
      # @param name [String] package name
      # @param version [String] package version
      # @return [Array<Hash>] array of vulnerability hashes
      def query(ecosystem:, name:, version:)
        payload = {
          package: {
            name: name,
            ecosystem: ecosystem
          },
          version: version
        }

        response = post("/query", payload)
        fetch_all_pages(response, payload)
      end

      # Batch query vulnerabilities for multiple packages.
      # More efficient than individual queries for large dependency sets.
      #
      # @param packages [Array<Hash>] array of {ecosystem:, name:, version:} hashes
      # @return [Array<Array<Hash>>] array of vulnerability arrays, one per input package
      def query_batch(packages)
        return [] if packages.empty?

        results = Array.new(packages.size) { [] }

        packages.each_slice(BATCH_SIZE).with_index do |batch, batch_idx|
          queries = batch.map do |pkg|
            {
              package: {
                name: pkg[:name],
                ecosystem: pkg[:ecosystem]
              },
              version: pkg[:version]
            }
          end

          response = post("/querybatch", { queries: queries })
          batch_results = response["results"] || []

          batch_results.each_with_index do |result, idx|
            global_idx = batch_idx * BATCH_SIZE + idx
            results[global_idx] = result["vulns"] || []
          end
        end

        results
      end

      # Fetch full details for a specific vulnerability by ID.
      #
      # @param vuln_id [String] vulnerability ID (e.g., "CVE-2024-1234", "GHSA-xxxx")
      # @return [Hash] full vulnerability data
      def get_vulnerability(vuln_id)
        get("/vulns/#{URI.encode_uri_component(vuln_id)}")
      end

      private

      def post(path, payload)
        uri = URI("#{API_BASE}#{path}")
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(payload)

        execute_request(uri, request)
      end

      def get(path)
        uri = URI("#{API_BASE}#{path}")
        request = Net::HTTP::Get.new(uri)
        request["Content-Type"] = "application/json"

        execute_request(uri, request)
      end

      def execute_request(uri, request)
        http = http_client(uri)
        response = http.request(request)

        case response
        when Net::HTTPSuccess
          JSON.parse(response.body)
        else
          raise ApiError, "OSV API error: #{response.code} #{response.message}"
        end
      rescue JSON::ParserError => e
        raise ApiError, "Invalid JSON response from OSV API: #{e.message}"
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise ApiError, "OSV API timeout: #{e.message}"
      rescue SocketError, Errno::ECONNREFUSED => e
        raise ApiError, "OSV API connection error: #{e.message}"
      rescue OpenSSL::SSL::SSLError => e
        raise ApiError, "OSV API SSL error: #{e.message}"
      end

      def http_client(uri)
        key = "#{uri.host}:#{uri.port}"
        @http_clients[key] ||= begin
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = 10
          http.read_timeout = 30
          http
        end
      end

      MAX_PAGES = 100

      def fetch_all_pages(response, original_payload)
        vulns = response["vulns"] || []
        page_token = response["next_page_token"]
        pages_fetched = 0

        while page_token && pages_fetched < MAX_PAGES
          payload = original_payload.merge(page_token: page_token)
          response = post("/query", payload)
          vulns.concat(response["vulns"] || [])
          page_token = response["next_page_token"]
          pages_fetched += 1
        end

        vulns
      end
    end
  end
end
