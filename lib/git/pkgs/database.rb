# frozen_string_literal: true

require "sequel"

# Set up a placeholder DB so models can be defined before connection
DB = Sequel.sqlite
Sequel::Model.plugin :timestamps, update_on_create: true
Sequel::Model.plugin :update_or_create
Sequel::Model.require_valid_table = false
Sequel::Model.unrestrict_primary_key
# Allow mass assignment of any column (similar to AR default behavior)
Sequel::Model.strict_param_setting = false

module Git
  module Pkgs
    class Database
      DB_FILE = "pkgs.sqlite3"
      SCHEMA_VERSION = 2

      class << self
        attr_accessor :db
      end

      def self.path(git_dir = nil)
        return Git::Pkgs.db_path if Git::Pkgs.db_path

        git_dir ||= find_git_dir
        File.join(git_dir, DB_FILE)
      end

      def self.find_git_dir
        if Git::Pkgs.git_dir
          return Git::Pkgs.git_dir if File.directory?(Git::Pkgs.git_dir)

          raise NotInGitRepoError, "GIT_DIR '#{Git::Pkgs.git_dir}' does not exist"
        end

        dir = Git::Pkgs.work_tree || Dir.pwd
        loop do
          git_dir = File.join(dir, ".git")
          return git_dir if File.directory?(git_dir)

          parent = File.dirname(dir)
          raise NotInGitRepoError, "Not in a git repository" if parent == dir

          dir = parent
        end
      end

      def self.connect(git_dir = nil, check_version: true)
        disconnect
        db_path = path(git_dir)
        @db = Sequel.sqlite(db_path)
        Sequel::Model.db = @db
        refresh_models
        check_version! if check_version
        @db
      end

      def self.connect_memory
        disconnect
        @db = Sequel.sqlite
        Sequel::Model.db = @db
        refresh_models
        create_schema
        @db
      end

      def self.disconnect
        return unless @db

        Sequel::DATABASES.delete(@db)
        @db.disconnect rescue nil
        @db = nil
      end

      def self.refresh_models
        # Force models to use the new database connection
        [
          Git::Pkgs::Models::Branch,
          Git::Pkgs::Models::BranchCommit,
          Git::Pkgs::Models::Commit,
          Git::Pkgs::Models::Manifest,
          Git::Pkgs::Models::DependencyChange,
          Git::Pkgs::Models::DependencySnapshot,
          Git::Pkgs::Models::Package,
          Git::Pkgs::Models::Vulnerability,
          Git::Pkgs::Models::VulnerabilityPackage
        ].each do |model|
          model.dataset = @db[model.table_name]
          # Clear all cached association data that may reference old db
          model.association_reflections.each_value do |reflection|
            reflection.delete(:_dataset)
            reflection.delete(:associated_eager_dataset)
            reflection.delete(:placeholder_eager_loader)
            reflection.delete(:placeholder_eager_graph_loader)
            if reflection[:cache]
              reflection[:cache].clear
            end
          end
          # Clear model instance caches
          model.instance_variable_set(:@columns, nil) if model.instance_variable_defined?(:@columns)
        rescue Sequel::Error
          # Table may not exist yet
        end
      end

      def self.exists?(git_dir = nil)
        File.exist?(path(git_dir))
      end

      def self.create_schema(with_indexes: true)
        @db.create_table?(:schema_info) do
          Integer :version, null: false
        end

        @db.create_table?(:branches) do
          primary_key :id
          String :name, null: false
          String :last_analyzed_sha
          DateTime :created_at
          DateTime :updated_at
          index :name, unique: true
        end

        @db.create_table?(:commits) do
          primary_key :id
          String :sha, null: false
          String :message, text: true
          String :author_name
          String :author_email
          DateTime :committed_at
          TrueClass :has_dependency_changes, default: false
          DateTime :created_at
          DateTime :updated_at
          index :sha, unique: true
        end

        @db.create_table?(:branch_commits) do
          primary_key :id
          foreign_key :branch_id, :branches
          foreign_key :commit_id, :commits
          Integer :position
          index [:branch_id, :commit_id], unique: true
        end

        @db.create_table?(:manifests) do
          primary_key :id
          String :path, null: false
          String :ecosystem
          String :kind
          DateTime :created_at
          DateTime :updated_at
          index :path
        end

        @db.create_table?(:dependency_changes) do
          primary_key :id
          foreign_key :commit_id, :commits
          foreign_key :manifest_id, :manifests
          String :name, null: false
          String :ecosystem
          String :purl
          String :change_type, null: false
          String :requirement
          String :previous_requirement
          String :dependency_type
          DateTime :created_at
          DateTime :updated_at
        end

        @db.create_table?(:dependency_snapshots) do
          primary_key :id
          foreign_key :commit_id, :commits
          foreign_key :manifest_id, :manifests
          String :name, null: false
          String :ecosystem
          String :purl
          String :requirement
          String :dependency_type
          DateTime :created_at
          DateTime :updated_at
        end

        @db.create_table?(:packages) do
          primary_key :id
          String :purl, null: false
          String :ecosystem, null: false
          String :name, null: false
          String :latest_version
          String :license
          String :description, text: true
          String :homepage
          String :repository_url
          String :source
          DateTime :enriched_at
          DateTime :vulns_synced_at
          DateTime :created_at
          DateTime :updated_at
          index :purl, unique: true
          index [:ecosystem, :name]
        end

        # Core vulnerability data (one row per CVE/GHSA)
        @db.create_table?(:vulnerabilities) do
          String :id, primary_key: true          # CVE-2024-1234, GHSA-xxxx, etc.
          String :aliases, text: true            # comma-separated other IDs for same vuln
          String :severity                       # critical, high, medium, low
          Float :cvss_score
          String :cvss_vector
          String :references, text: true         # JSON array of {type, url} objects
          String :summary, text: true
          String :details, text: true
          DateTime :published_at                 # when vuln was disclosed
          DateTime :withdrawn_at                 # when vuln was retracted (if ever)
          DateTime :modified_at                  # when OSV record was last modified
          DateTime :fetched_at, null: false      # when we last fetched from OSV
        end

        # Which packages are affected by each vulnerability
        # One vuln can affect multiple packages, each with different version ranges
        @db.create_table?(:vulnerability_packages) do
          primary_key :id
          String :vulnerability_id, null: false
          String :ecosystem, null: false         # OSV ecosystem name
          String :package_name, null: false
          String :affected_versions, text: true  # version range expression
          String :fixed_versions, text: true     # comma-separated list
          foreign_key [:vulnerability_id], :vulnerabilities
          index [:ecosystem, :package_name]
          index [:vulnerability_id]
          unique [:vulnerability_id, :ecosystem, :package_name]
        end

        set_version
        create_bulk_indexes if with_indexes
        refresh_models
      end

      def self.create_bulk_indexes
        @db.alter_table(:dependency_changes) do
          add_index :name, if_not_exists: true
          add_index :ecosystem, if_not_exists: true
          add_index :purl, if_not_exists: true
          add_index [:commit_id, :name], if_not_exists: true
        end

        @db.alter_table(:dependency_snapshots) do
          add_index [:commit_id, :manifest_id, :name], unique: true, name: "idx_snapshots_unique", if_not_exists: true
          add_index :name, if_not_exists: true
          add_index :ecosystem, if_not_exists: true
          add_index :purl, if_not_exists: true
        end
      end

      def self.stored_version
        return nil unless @db.table_exists?(:schema_info)

        @db[:schema_info].get(:version)
      end

      def self.set_version(version = SCHEMA_VERSION)
        @db[:schema_info].delete
        @db[:schema_info].insert(version: version)
      end

      def self.needs_upgrade?
        return false unless @db.table_exists?(:commits)
        return true unless @db.table_exists?(:schema_info)

        stored = stored_version || 0
        stored < SCHEMA_VERSION
      end

      def self.check_version!
        return unless needs_upgrade?

        migrate!
      end

      def self.migrate!
        stored = stored_version || 0

        # Migration from v1 to v2: add vuln tables
        if stored < 2
          migrate_to_v2!
        end

        set_version
        refresh_models
      end

      def self.migrate_to_v2!
        @db.create_table?(:packages) do
          primary_key :id
          String :purl, null: false
          String :ecosystem, null: false
          String :name, null: false
          String :latest_version
          String :license
          String :description, text: true
          String :homepage
          String :repository_url
          String :source
          DateTime :enriched_at
          DateTime :vulns_synced_at
          DateTime :created_at
          DateTime :updated_at
          index :purl, unique: true
          index [:ecosystem, :name]
        end

        @db.create_table?(:vulnerabilities) do
          String :id, primary_key: true
          String :aliases, text: true
          String :severity
          Float :cvss_score
          String :cvss_vector
          String :references, text: true
          String :summary, text: true
          String :details, text: true
          DateTime :published_at
          DateTime :withdrawn_at
          DateTime :modified_at
          DateTime :fetched_at, null: false
        end

        @db.create_table?(:vulnerability_packages) do
          primary_key :id
          String :vulnerability_id, null: false
          String :ecosystem, null: false
          String :package_name, null: false
          String :affected_versions, text: true
          String :fixed_versions, text: true
          foreign_key [:vulnerability_id], :vulnerabilities
          index [:ecosystem, :package_name]
          index [:vulnerability_id]
          unique [:vulnerability_id, :ecosystem, :package_name]
        end

        # Add purl column to existing tables if missing
        unless @db.schema(:dependency_changes).any? { |col, _| col == :purl }
          @db.alter_table(:dependency_changes) do
            add_column :purl, String
            add_index :purl, if_not_exists: true
          end
        end

        unless @db.schema(:dependency_snapshots).any? { |col, _| col == :purl }
          @db.alter_table(:dependency_snapshots) do
            add_column :purl, String
            add_index :purl, if_not_exists: true
          end
        end
      end

      def self.optimize_for_bulk_writes
        @db.run("PRAGMA synchronous = OFF")
        @db.run("PRAGMA journal_mode = WAL")
        @db.run("PRAGMA cache_size = -64000")
      end

      def self.optimize_for_reads
        @db.run("PRAGMA synchronous = NORMAL")
      end

      def self.drop(git_dir = nil)
        @db&.disconnect
        @db = nil
        File.delete(path(git_dir)) if exists?(git_dir)
      end
    end
  end
end
