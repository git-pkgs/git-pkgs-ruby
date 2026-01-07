# frozen_string_literal: true

module Git
  module Pkgs
    module Models
      class Package < Sequel::Model
        STALE_THRESHOLD = 86400 # 24 hours

        dataset_module do
          def by_ecosystem(ecosystem)
            where(ecosystem: ecosystem)
          end

          def needs_vuln_sync
            where(vulns_synced_at: nil).or { vulns_synced_at < Time.now - STALE_THRESHOLD }
          end

          def synced
            where { vulns_synced_at >= Time.now - STALE_THRESHOLD }
          end
        end

        def needs_vuln_sync?
          vulns_synced_at.nil? || vulns_synced_at < Time.now - STALE_THRESHOLD
        end

        def mark_vulns_synced
          update(vulns_synced_at: Time.now)
        end

        def vulnerabilities
          osv_ecosystem = Ecosystems.to_osv(ecosystem)
          return [] unless osv_ecosystem

          VulnerabilityPackage
            .where(ecosystem: osv_ecosystem, package_name: name)
            .map(&:vulnerability)
            .compact
        end

        def self.find_or_create_by_purl(purl:, ecosystem: nil, name: nil)
          existing = first(purl: purl)
          return existing if existing

          create(purl: purl, ecosystem: ecosystem, name: name)
        end

        def self.generate_purl(ecosystem, name)
          Ecosystems.generate_purl(ecosystem, name)
        end
      end
    end
  end
end
