# frozen_string_literal: true

require "active_record"
require "sqlite3"

module Git
  module Pkgs
    class Database
      DB_FILE = "pkgs.sqlite3"
      SCHEMA_VERSION = 1

      def self.path(git_dir = nil)
        git_dir ||= find_git_dir
        File.join(git_dir, DB_FILE)
      end

      def self.find_git_dir
        dir = Dir.pwd
        loop do
          git_dir = File.join(dir, ".git")
          return git_dir if File.directory?(git_dir)

          parent = File.dirname(dir)
          raise NotInGitRepoError, "Not in a git repository" if parent == dir

          dir = parent
        end
      end

      def self.connect(git_dir = nil, check_version: true)
        db_path = path(git_dir)
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3",
          database: db_path
        )
        check_version! if check_version
      end

      def self.connect_memory
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3",
          database: ":memory:"
        )
        create_schema
      end

      def self.exists?(git_dir = nil)
        File.exist?(path(git_dir))
      end

      def self.create_schema(with_indexes: true)
        ActiveRecord::Schema.define do
          create_table :schema_info, if_not_exists: true do |t|
            t.integer :version, null: false
          end

          create_table :branches, if_not_exists: true do |t|
            t.string :name, null: false
            t.string :last_analyzed_sha
            t.timestamps
          end
          add_index :branches, :name, unique: true, if_not_exists: true

          create_table :commits, if_not_exists: true do |t|
            t.string :sha, null: false
            t.text :message
            t.string :author_name
            t.string :author_email
            t.datetime :committed_at
            t.boolean :has_dependency_changes, default: false
            t.timestamps
          end
          add_index :commits, :sha, unique: true, if_not_exists: true

          create_table :branch_commits, if_not_exists: true do |t|
            t.references :branch, foreign_key: true
            t.references :commit, foreign_key: true
            t.integer :position
          end
          add_index :branch_commits, [:branch_id, :commit_id], unique: true, if_not_exists: true

          create_table :manifests, if_not_exists: true do |t|
            t.string :path, null: false
            t.string :ecosystem
            t.string :kind
            t.timestamps
          end
          add_index :manifests, :path, if_not_exists: true

          create_table :dependency_changes, if_not_exists: true do |t|
            t.references :commit, foreign_key: true
            t.references :manifest, foreign_key: true
            t.string :name, null: false
            t.string :ecosystem
            t.string :change_type, null: false
            t.string :requirement
            t.string :previous_requirement
            t.string :dependency_type
            t.timestamps
          end

          create_table :dependency_snapshots, if_not_exists: true do |t|
            t.references :commit, foreign_key: true
            t.references :manifest, foreign_key: true
            t.string :name, null: false
            t.string :ecosystem
            t.string :requirement
            t.string :dependency_type
            t.timestamps
          end
        end

        set_version
        create_bulk_indexes if with_indexes
      end

      def self.create_bulk_indexes
        conn = ActiveRecord::Base.connection

        # dependency_changes indexes
        conn.add_index :dependency_changes, :name, if_not_exists: true
        conn.add_index :dependency_changes, :ecosystem, if_not_exists: true
        conn.add_index :dependency_changes, [:commit_id, :name], if_not_exists: true

        # dependency_snapshots indexes
        conn.add_index :dependency_snapshots, [:commit_id, :manifest_id, :name],
                       unique: true, name: "idx_snapshots_unique", if_not_exists: true
        conn.add_index :dependency_snapshots, :name, if_not_exists: true
        conn.add_index :dependency_snapshots, :ecosystem, if_not_exists: true
      end

      def self.stored_version
        conn = ActiveRecord::Base.connection
        return nil unless conn.table_exists?(:schema_info)

        result = conn.select_value("SELECT version FROM schema_info LIMIT 1")
        result&.to_i
      end

      def self.set_version(version = SCHEMA_VERSION)
        conn = ActiveRecord::Base.connection
        conn.execute("DELETE FROM schema_info")
        conn.execute("INSERT INTO schema_info (version) VALUES (#{version})")
      end

      def self.needs_upgrade?
        conn = ActiveRecord::Base.connection

        # No tables at all = fresh database, no upgrade needed
        return false unless conn.table_exists?(:commits)

        # Has commits table but no schema_info = old database, needs upgrade
        return true unless conn.table_exists?(:schema_info)

        # Check version
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
        conn = ActiveRecord::Base.connection
        conn.execute("PRAGMA synchronous = OFF")
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA cache_size = -64000") # 64MB cache
      end

      def self.optimize_for_reads
        conn = ActiveRecord::Base.connection
        conn.execute("PRAGMA synchronous = NORMAL")
      end

      def self.drop(git_dir = nil)
        ActiveRecord::Base.connection.close if ActiveRecord::Base.connected?
        File.delete(path(git_dir)) if exists?(git_dir)
      end
    end
  end
end
