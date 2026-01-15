# frozen_string_literal: true

module Git
  module Pkgs
    module Models
      class Version < Sequel::Model
        STALE_THRESHOLD = 86400 # 24 hours

        many_to_one :package, key: :package_purl, primary_key: :purl

        def parsed_purl
          @parsed_purl ||= Purl.parse(purl)
        end

        def version_string
          parsed_purl.version
        end

        def registry_url
          parsed_purl.registry_url
        end

        def enriched?
          !enriched_at.nil?
        end

        def needs_enrichment?
          enriched_at.nil? || enriched_at < Time.now - STALE_THRESHOLD
        end

        def enrich_from_api(data)
          licenses = data["licenses"]
          license = case licenses
                    when Array then licenses.first
                    when String then licenses
                    end
          license ||= data["spdx_expression"]

          update(
            license: license,
            integrity: data["integrity"],
            published_at: data["published_at"] ? Time.parse(data["published_at"]) : nil,
            enriched_at: Time.now
          )
        end

        def self.find_or_create_by_purl(purl:, package_purl:)
          existing = first(purl: purl)
          return existing if existing

          create(purl: purl, package_purl: package_purl)
        end

        # Find the latest version of a package that was published before a given date.
        # Compares versions using semantic versioning.
        #
        # @param package_purl [String] base purl without version
        # @param date [Time] cutoff date
        # @return [Version, nil] the latest version as of that date
        def self.latest_as_of(package_purl:, date:)
          candidates = where(package_purl: package_purl)
            .where { published_at <= date }
            .where(Sequel.~(published_at: nil))
            .all

          return nil if candidates.empty?

          candidates.max_by { |v| parse_semver(v.version_string) }
        end

        def self.parse_semver(version)
          cleaned = version.to_s.sub(/^v/i, "")
          parts = cleaned.split(".").first(3).map(&:to_i)
          parts + [0] * (3 - parts.length)
        end
      end
    end
  end
end
