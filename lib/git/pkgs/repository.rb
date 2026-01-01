# frozen_string_literal: true

require "rugged"

module Git
  module Pkgs
    class Repository
      attr_reader :path

      def initialize(path = Dir.pwd)
        @path = path
        @rugged = Rugged::Repository.new(path)
      end

      def git_dir
        @rugged.path.chomp("/")
      end

      def default_branch
        # Try origin/HEAD first (what GitHub/GitLab set as default)
        if @rugged.references["refs/remotes/origin/HEAD"]
          ref = @rugged.references["refs/remotes/origin/HEAD"].resolve
          return ref.name.sub("refs/remotes/origin/", "")
        end

        # Fall back to current HEAD
        head = @rugged.head
        head.name.sub("refs/heads/", "")
      rescue Rugged::ReferenceError
        # Last resort: common default names
        %w[main master].find { |name| branch_exists?(name) } || "main"
      end

      def branch_exists?(name)
        @rugged.branches[name] != nil
      end

      def branch_target(name)
        @rugged.branches[name]&.target_id
      end

      def walk(branch_name, since_sha = nil)
        walker = Rugged::Walker.new(@rugged)
        walker.sorting(Rugged::SORT_TOPO | Rugged::SORT_REVERSE)

        branch = @rugged.branches[branch_name]
        raise Error, "Branch '#{branch_name}' not found" unless branch

        if since_sha
          begin
            walker.hide(@rugged.lookup(since_sha).oid)
          rescue Rugged::OdbError
            # Commit not found, walk from beginning
          end
        end

        walker.push(branch.target_id)
        walker
      end

      def lookup(sha)
        @rugged.lookup(sha)
      end

      def blob_paths(rugged_commit)
        paths = []

        if rugged_commit.parents.empty?
          rugged_commit.tree.walk_blobs(:postorder) do |root, entry|
            paths << {
              status: :added,
              path: "#{root}#{entry[:name]}"
            }
          end
        else
          diffs = rugged_commit.parents[0].diff(rugged_commit)
          diffs.each_delta do |delta|
            paths << {
              status: delta.status,
              path: delta.new_file[:path]
            }
          end
        end

        paths
      end

      def content_at_commit(rugged_commit, file_path)
        entry = rugged_commit.tree.path(file_path)
        blob = @rugged.lookup(entry[:oid])
        blob.content
      rescue Rugged::TreeError
        nil
      end

      def content_before_commit(rugged_commit, file_path)
        return nil if rugged_commit.parents.empty?

        content_at_commit(rugged_commit.parents[0], file_path)
      end

      def blob_oid_at_commit(rugged_commit, file_path)
        entry = rugged_commit.tree.path(file_path)
        entry[:oid]
      rescue Rugged::TreeError
        nil
      end

      def blob_content(oid)
        blob = @rugged.lookup(oid)
        blob.content
      rescue Rugged::OdbError
        nil
      end

      def merge_commit?(rugged_commit)
        rugged_commit.parents.length > 1
      end

      def head_sha
        @rugged.head.target_id
      end

      def rev_parse(ref)
        @rugged.rev_parse(ref).oid
      rescue Rugged::ReferenceError, Rugged::InvalidError
        nil
      end
    end
  end
end
