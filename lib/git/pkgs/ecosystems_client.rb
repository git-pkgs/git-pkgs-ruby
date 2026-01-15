# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Git
  module Pkgs
    # Client for the ecosyste.ms Packages API.
    # https://packages.ecosyste.ms/docs
    class EcosystemsClient
      API_BASE = "https://packages.ecosyste.ms/api/v1"
      BATCH_SIZE = 100 # Max purls per batch request

      class Error < StandardError; end
      class ApiError < Error; end

      def initialize
        @http_clients = {}
      end

      # Batch lookup packages by purl.
      #
      # @param purls [Array<String>] array of package URLs (e.g., "pkg:gem/rails")
      # @return [Hash<String, Hash>] hash keyed by purl with package data
      def bulk_lookup(purls)
        return {} if purls.empty?

        results = {}

        purls.each_slice(BATCH_SIZE) do |batch|
          response = post("/packages/bulk_lookup", { purls: batch })
          (response || []).each do |pkg|
            results[pkg["purl"]] = pkg if pkg["purl"]
          end
        end

        results
      end

      # Lookup a single package by purl.
      #
      # @param purl [String] package URL
      # @return [Hash, nil] package data or nil if not found
      def lookup(purl)
        results = bulk_lookup([purl])
        results[purl]
      end

      # Lookup a specific version by purl with version.
      # Returns version-level data including integrity hash.
      #
      # @param purl [String] package URL with version (e.g., "pkg:gem/rake@13.3.1")
      # @return [Hash, nil] version data or nil if not found
      def lookup_version(purl)
        parsed = Purl.parse(purl)
        return nil unless parsed.version

        url = parsed.ecosystems_version_api_url
        return nil unless url

        fetch_url(url)
      rescue Purl::Error
        nil
      end

      # Batch lookup versions by purl.
      # Fetches each version individually (no batch API for versions).
      #
      # @param purls [Array<String>] array of versioned package URLs
      # @return [Hash<String, Hash>] hash keyed by purl with version data
      def bulk_lookup_versions(purls)
        results = {}
        purls.each do |purl|
          data = lookup_version(purl)
          results[purl] = data if data
        end
        results
      end

      # Lookup all versions for a package by purl.
      # Returns version history with published_at dates.
      #
      # @param purl [String] package URL without version (e.g., "pkg:gem/rails")
      # @return [Array<Hash>, nil] array of version data or nil if not found
      def lookup_all_versions(purl)
        parsed = Purl.parse(purl)
        base_url = parsed.ecosystems_package_api_url
        return nil unless base_url

        fetch_all_pages("#{base_url}/versions")
      rescue Purl::Error
        nil
      end

      # Batch lookup all versions for multiple packages.
      # Currently fetches each package individually.
      # Designed for future batch API support.
      #
      # @param purls [Array<String>] array of package URLs without versions
      # @return [Hash<String, Array<Hash>>] hash keyed by purl with version arrays
      def bulk_lookup_all_versions(purls)
        results = {}
        purls.each do |purl|
          data = lookup_all_versions(purl)
          results[purl] = data if data
        end
        results
      end

      private

      def fetch_url(url)
        uri = URI(url)
        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"
        execute_request(uri, request)
      end

      def fetch_all_pages(base_url, per_page: 100)
        results = []
        page = 1

        loop do
          url = "#{base_url}?page=#{page}&per_page=#{per_page}"
          data = fetch_url(url)
          break unless data.is_a?(Array) && data.any?

          results.concat(data)
          break if data.length < per_page

          page += 1
        end

        results.empty? ? nil : results
      end

      def get(path)
        uri = URI("#{API_BASE}#{path}")
        request = Net::HTTP::Get.new(uri)
        request["Accept"] = "application/json"

        execute_request(uri, request)
      end

      def post(path, payload)
        uri = URI("#{API_BASE}#{path}")
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request.body = JSON.generate(payload)

        execute_request(uri, request)
      end

      def execute_request(uri, request)
        http = http_client(uri)
        response = http.request(request)

        case response
        when Net::HTTPSuccess
          JSON.parse(response.body)
        when Net::HTTPNotFound
          nil
        else
          raise ApiError, "ecosyste.ms API error: #{response.code} #{response.message}"
        end
      rescue JSON::ParserError => e
        raise ApiError, "Invalid JSON response from ecosyste.ms API: #{e.message}"
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise ApiError, "ecosyste.ms API timeout: #{e.message}"
      rescue SocketError, Errno::ECONNREFUSED => e
        raise ApiError, "ecosyste.ms API connection error: #{e.message}"
      rescue OpenSSL::SSL::SSLError => e
        raise ApiError, "ecosyste.ms API SSL error: #{e.message}"
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
    end
  end
end
