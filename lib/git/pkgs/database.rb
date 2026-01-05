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
      SCHEMA_VERSION = 1

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
          Git::Pkgs::Models::DependencySnapshot
        ].each do |model|
          model.dataset = @db[model.table_name]
          # Clear cached association datasets and loaders that may reference old db
          model.association_reflections.each_value do |reflection|
            if reflection[:cache]
              reflection[:cache].delete(:_dataset)
              reflection[:cache].delete(:associated_eager_dataset)
              reflection[:cache].delete(:placeholder_eager_loader)
            end
          end
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
          String :requirement
          String :dependency_type
          DateTime :created_at
          DateTime :updated_at
        end

        set_version
        create_bulk_indexes if with_indexes
        refresh_models
      end

      def self.create_bulk_indexes
        @db.alter_table(:dependency_changes) do
          add_index :name, if_not_exists: true
          add_index :ecosystem, if_not_exists: true
          add_index [:commit_id, :name], if_not_exists: true
        end

        @db.alter_table(:dependency_snapshots) do
          add_index [:commit_id, :manifest_id, :name], unique: true, name: "idx_snapshots_unique", if_not_exists: true
          add_index :name, if_not_exists: true
          add_index :ecosystem, if_not_exists: true
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

        stored = stored_version || 0
        $stderr.puts "Database schema is outdated (version #{stored}, current is #{SCHEMA_VERSION})."
        $stderr.puts "Run 'git pkgs upgrade' to update."
        exit 1
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
