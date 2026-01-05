# frozen_string_literal: true

module Git
  module Pkgs
    module Models
      class BranchCommit < Sequel::Model
        many_to_one :branch
        many_to_one :commit
      end
    end
  end
end
