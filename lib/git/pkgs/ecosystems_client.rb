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

      private

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
