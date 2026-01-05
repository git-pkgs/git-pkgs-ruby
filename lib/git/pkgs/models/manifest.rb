# frozen_string_literal: true

module Git
  module Pkgs
    module Models
      class Manifest < Sequel::Model
        one_to_many :dependency_changes
        one_to_many :dependency_snapshots

        def self.find_or_create(path:, ecosystem: nil, kind: nil)
          existing = first(path: path)
          return existing if existing

          create(path: path, ecosystem: ecosystem, kind: kind)
        end
      end
    end
  end
end
