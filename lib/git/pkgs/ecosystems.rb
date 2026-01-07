# frozen_string_literal: true

module Git
  module Pkgs
    # Maps ecosystem names between bibliothecary, purl, and OSV formats.
    # Bibliothecary uses lowercase names internally.
    # Purl uses its own type names.
    # OSV uses mixed case names that differ from both.
    module Ecosystems
      # Mapping from bibliothecary ecosystem names to OSV and purl equivalents
      MAPPINGS = {
        "npm" => { osv: "npm", purl: "npm" },
        "rubygems" => { osv: "RubyGems", purl: "gem" },
        "pypi" => { osv: "PyPI", purl: "pypi" },
        "cargo" => { osv: "crates.io", purl: "cargo" },
        "maven" => { osv: "Maven", purl: "maven" },
        "nuget" => { osv: "NuGet", purl: "nuget" },
        "packagist" => { osv: "Packagist", purl: "composer" },
        "go" => { osv: "Go", purl: "golang" },
        "hex" => { osv: "Hex", purl: "hex" },
        "pub" => { osv: "Pub", purl: "pub" }
      }.freeze

      # Reverse mappings for lookups from OSV/purl to bibliothecary
      OSV_TO_BIBLIOTHECARY = MAPPINGS.transform_values { |v| v[:osv] }.invert.freeze
      PURL_TO_BIBLIOTHECARY = MAPPINGS.transform_values { |v| v[:purl] }.invert.freeze

      class << self
        # Convert bibliothecary ecosystem name to OSV format
        # @param ecosystem [String] bibliothecary ecosystem name (e.g., "rubygems")
        # @return [String, nil] OSV ecosystem name (e.g., "RubyGems") or nil if not mapped
        def to_osv(ecosystem)
          MAPPINGS.dig(ecosystem.to_s.downcase, :osv)
        end

        # Convert bibliothecary ecosystem name to purl type
        # @param ecosystem [String] bibliothecary ecosystem name (e.g., "rubygems")
        # @return [String, nil] purl type (e.g., "gem") or nil if not mapped
        def to_purl(ecosystem)
          MAPPINGS.dig(ecosystem.to_s.downcase, :purl)
        end

        # Convert OSV ecosystem name to bibliothecary format
        # @param osv_ecosystem [String] OSV ecosystem name (e.g., "RubyGems")
        # @return [String, nil] bibliothecary ecosystem name (e.g., "rubygems") or nil if not mapped
        def from_osv(osv_ecosystem)
          OSV_TO_BIBLIOTHECARY[osv_ecosystem]
        end

        # Convert purl type to bibliothecary ecosystem name
        # @param purl_type [String] purl type (e.g., "gem")
        # @return [String, nil] bibliothecary ecosystem name (e.g., "rubygems") or nil if not mapped
        def from_purl(purl_type)
          PURL_TO_BIBLIOTHECARY[purl_type]
        end

        # Check if an ecosystem is supported for vulnerability scanning
        # @param ecosystem [String] bibliothecary ecosystem name
        # @return [Boolean]
        def supported?(ecosystem)
          MAPPINGS.key?(ecosystem.to_s.downcase)
        end

        # List all supported bibliothecary ecosystem names
        # @return [Array<String>]
        def supported_ecosystems
          MAPPINGS.keys
        end

        # Generate a purl (package URL) for a given ecosystem and package name
        # @param ecosystem [String] bibliothecary ecosystem name (e.g., "rubygems")
        # @param name [String] package name
        # @return [String, nil] purl string (e.g., "pkg:gem/rails") or nil if ecosystem not supported
        def generate_purl(ecosystem, name)
          purl_type = to_purl(ecosystem)
          return nil unless purl_type

          "pkg:#{purl_type}/#{name}"
        end
      end
    end
  end
end
