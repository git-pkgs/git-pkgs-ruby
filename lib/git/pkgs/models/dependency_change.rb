# frozen_string_literal: true

module Git
  module Pkgs
    module Models
      class DependencyChange < Sequel::Model
        many_to_one :commit
        many_to_one :manifest

        dataset_module do
          def added
            where(change_type: "added")
          end

          def modified
            where(change_type: "modified")
          end

          def removed
            where(change_type: "removed")
          end

          def for_package(name)
            where(name: name)
          end

          def for_platform(platform)
            where(ecosystem: platform)
          end
        end

        def purl(with_version: true)
          version = nil
          if with_version && manifest&.kind == "lockfile"
            version = requirement
          end
          PurlHelper.build_purl(ecosystem: ecosystem, name: name, version: version)
        end
      end
    end
  end
end
