# frozen_string_literal: true

module Git
  module Pkgs
    module Models
      class Branch < Sequel::Model
        one_to_many :branch_commits
        many_to_many :commits, join_table: :branch_commits

        def self.find_or_create(name)
          first(name: name) || create(name: name)
        end
      end
    end
  end
end
