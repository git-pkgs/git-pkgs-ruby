# frozen_string_literal: true

require "test_helper"

class Git::Pkgs::TestConfig < Minitest::Test
  include TestHelpers

  def setup
    create_test_repo
    Git::Pkgs::Config.reset!
  end

  def teardown
    cleanup_test_repo
    Git::Pkgs::Config.reset!
    Git::Pkgs.work_tree = nil
    Git::Pkgs.git_dir = nil
  end

  def test_ignored_dirs_returns_empty_array_when_not_configured
    with_pkgs_dir do
      assert_equal [], Git::Pkgs::Config.ignored_dirs
    end
  end

  def test_ignored_dirs_returns_configured_values
    git("config --add pkgs.ignoredDirs third_party")
    git("config --add pkgs.ignoredDirs external")

    with_pkgs_dir do
      Git::Pkgs::Config.reset!
      assert_equal ["third_party", "external"], Git::Pkgs::Config.ignored_dirs
    end
  end

  def test_ignored_files_returns_empty_array_when_not_configured
    with_pkgs_dir do
      assert_equal [], Git::Pkgs::Config.ignored_files
    end
  end

  def test_ignored_files_returns_configured_values
    git("config --add pkgs.ignoredFiles test/fixtures/package.json")

    with_pkgs_dir do
      Git::Pkgs::Config.reset!
      assert_equal ["test/fixtures/package.json"], Git::Pkgs::Config.ignored_files
    end
  end

  def test_ecosystems_returns_empty_array_when_not_configured
    with_pkgs_dir do
      assert_equal [], Git::Pkgs::Config.ecosystems
    end
  end

  def test_ecosystems_returns_configured_values
    git("config --add pkgs.ecosystems rubygems")
    git("config --add pkgs.ecosystems npm")

    with_pkgs_dir do
      Git::Pkgs::Config.reset!
      assert_equal ["rubygems", "npm"], Git::Pkgs::Config.ecosystems
    end
  end

  def test_filter_ecosystem_returns_false_when_no_ecosystems_configured
    with_pkgs_dir do
      refute Git::Pkgs::Config.filter_ecosystem?("rubygems")
      refute Git::Pkgs::Config.filter_ecosystem?("npm")
      refute Git::Pkgs::Config.filter_ecosystem?("carthage")
      refute Git::Pkgs::Config.filter_ecosystem?("hex")
    end
  end

  def test_filter_ecosystem_returns_false_for_included_ecosystem
    git("config --add pkgs.ecosystems rubygems")
    git("config --add pkgs.ecosystems npm")

    with_pkgs_dir do
      Git::Pkgs::Config.reset!
      refute Git::Pkgs::Config.filter_ecosystem?("rubygems")
      refute Git::Pkgs::Config.filter_ecosystem?("npm")
    end
  end

  def test_filter_ecosystem_returns_true_for_excluded_ecosystem
    git("config --add pkgs.ecosystems rubygems")

    with_pkgs_dir do
      Git::Pkgs::Config.reset!
      assert Git::Pkgs::Config.filter_ecosystem?("npm")
      assert Git::Pkgs::Config.filter_ecosystem?("pypi")
    end
  end

  def test_filter_ecosystem_is_case_insensitive
    git("config --add pkgs.ecosystems RubyGems")

    with_pkgs_dir do
      Git::Pkgs::Config.reset!
      refute Git::Pkgs::Config.filter_ecosystem?("rubygems")
      refute Git::Pkgs::Config.filter_ecosystem?("RUBYGEMS")
    end
  end

  def test_configure_bibliothecary_adds_ignored_dirs
    git("config --add pkgs.ignoredDirs my_vendor")

    with_pkgs_dir do
      Git::Pkgs::Config.reset!
      original_dirs = Bibliothecary.configuration.ignored_dirs.dup
      Git::Pkgs::Config.configure_bibliothecary

      assert_includes Bibliothecary.configuration.ignored_dirs, "my_vendor"

      # Clean up
      Bibliothecary.configuration.ignored_dirs = original_dirs
    end
  end

  def test_configure_bibliothecary_adds_ignored_files
    git("config --add pkgs.ignoredFiles fixtures/Gemfile")

    with_pkgs_dir do
      Git::Pkgs::Config.reset!
      original_files = Bibliothecary.configuration.ignored_files.dup
      Git::Pkgs::Config.configure_bibliothecary

      assert_includes Bibliothecary.configuration.ignored_files, "fixtures/Gemfile"

      # Clean up
      Bibliothecary.configuration.ignored_files = original_files
    end
  end

  def with_pkgs_dir
    old_git_dir = Git::Pkgs.git_dir
    old_work_tree = Git::Pkgs.work_tree
    Git::Pkgs.git_dir = File.join(@test_dir, ".git")
    Git::Pkgs.work_tree = @test_dir
    yield
  ensure
    Git::Pkgs.git_dir = old_git_dir
    Git::Pkgs.work_tree = old_work_tree
  end
end
