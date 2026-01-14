# frozen_string_literal: true

module Git
  module Pkgs
    module Models
      class DependencySnapshot < Sequel::Model
        many_to_one :commit
        many_to_one :manifest

        dataset_module do
          def for_package(name)
            where(name: name)
          end

          def for_platform(platform)
            where(ecosystem: platform)
          end

          def at_commit(commit)
            where(commit: commit)
          end
        end

        def self.current_for_branch(branch)
          return dataset.where(false) unless branch.last_analyzed_sha

          commit = Commit.first(sha: branch.last_analyzed_sha)
          return dataset.where(false) unless commit

          where(commit: commit)
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
