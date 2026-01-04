# frozen_string_literal: true

require_relative "pkgs/version"
require_relative "pkgs/output"
require_relative "pkgs/color"
require_relative "pkgs/config"
require_relative "pkgs/cli"
require_relative "pkgs/database"
require_relative "pkgs/repository"
require_relative "pkgs/analyzer"

require_relative "pkgs/models/branch"
require_relative "pkgs/models/branch_commit"
require_relative "pkgs/models/commit"
require_relative "pkgs/models/manifest"
require_relative "pkgs/models/dependency_change"
require_relative "pkgs/models/dependency_snapshot"

require_relative "pkgs/commands/init"
require_relative "pkgs/commands/update"
require_relative "pkgs/commands/hooks"
require_relative "pkgs/commands/info"
require_relative "pkgs/commands/list"
require_relative "pkgs/commands/history"
require_relative "pkgs/commands/why"
require_relative "pkgs/commands/blame"
require_relative "pkgs/commands/stale"
require_relative "pkgs/commands/stats"
require_relative "pkgs/commands/diff"
require_relative "pkgs/commands/tree"
require_relative "pkgs/commands/branch"
require_relative "pkgs/commands/search"
require_relative "pkgs/commands/show"
require_relative "pkgs/commands/where"
require_relative "pkgs/commands/log"
require_relative "pkgs/commands/upgrade"
require_relative "pkgs/commands/schema"
require_relative "pkgs/commands/diff_driver"

module Git
  module Pkgs
    class Error < StandardError; end
    class NotInitializedError < Error; end
    class NotInGitRepoError < Error; end

    class << self
      attr_accessor :quiet, :git_dir, :work_tree, :db_path

      def configure_from_env
        @git_dir ||= presence(ENV["GIT_DIR"])
        @work_tree ||= presence(ENV["GIT_WORK_TREE"])
        @db_path ||= presence(ENV["GIT_PKGS_DB"])
      end

      def reset_config!
        @quiet = false
        @git_dir = nil
        @work_tree = nil
        @db_path = nil
      end

      def presence(value)
        value && !value.empty? ? value : nil
      end
    end
    self.quiet = false
  end
end
