# frozen_string_literal: true

require "purl"

module Git
  module Pkgs
    module PurlHelper
      # Mapping from Bibliothecary/ecosyste.ms ecosystem names to PURL types
      # Source: https://packages.ecosyste.ms/api/v1/registries/
      ECOSYSTEM_TO_PURL_TYPE = {
        "npm" => "npm",
        "go" => "golang",
        "docker" => "docker",
        "pypi" => "pypi",
        "nuget" => "nuget",
        "maven" => "maven",
        "packagist" => "composer",
        "cargo" => "cargo",
        "rubygems" => "gem",
        "cocoapods" => "cocoapods",
        "pub" => "pub",
        "bower" => "bower",
        "cpan" => "cpan",
        "alpine" => "alpine",
        "actions" => "githubactions",
        "cran" => "cran",
        "clojars" => "clojars",
        "conda" => "conda",
        "hex" => "hex",
        "hackage" => "hackage",
        "julia" => "julia",
        "swiftpm" => "swift",
        "openvsx" => "openvsx",
        "spack" => "spack",
        "homebrew" => "brew",
        "puppet" => "puppet",
        "deno" => "deno",
        "elm" => "elm",
        "vcpkg" => "vcpkg",
        "racket" => "racket",
        "bioconductor" => "bioconductor",
        "carthage" => "carthage",
        "elpa" => "melpa"
      }.freeze

      def self.purl_type_for(ecosystem)
        ECOSYSTEM_TO_PURL_TYPE.fetch(ecosystem, ecosystem)
      end

      def self.build_purl(ecosystem:, name:, version: nil)
        type = purl_type_for(ecosystem)
        Purl::PackageURL.new(type: type, name: name, version: version)
      end
    end
  end
end
