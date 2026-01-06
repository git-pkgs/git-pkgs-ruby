# frozen_string_literal: true

module Git
  module Pkgs
    module Models
      class Version < Sequel::Model
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
      end
    end
  end
end
