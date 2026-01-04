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
  end

  def test_ignored_dirs_returns_empty_array_when_not_configured
    Dir.chdir(@test_dir) do
      assert_equal [], Git::Pkgs::Config.ignored_dirs
    end
  end

  def test_ignored_dirs_returns_configured_values
    Dir.chdir(@test_dir) do
      system("git config --add pkgs.ignoredDirs third_party", out: File::NULL)
      system("git config --add pkgs.ignoredDirs external", out: File::NULL)
      Git::Pkgs::Config.reset!

      assert_equal ["third_party", "external"], Git::Pkgs::Config.ignored_dirs
    end
  end

  def test_ignored_files_returns_empty_array_when_not_configured
    Dir.chdir(@test_dir) do
      assert_equal [], Git::Pkgs::Config.ignored_files
    end
  end

  def test_ignored_files_returns_configured_values
    Dir.chdir(@test_dir) do
      system("git config --add pkgs.ignoredFiles test/fixtures/package.json", out: File::NULL)
      Git::Pkgs::Config.reset!

      assert_equal ["test/fixtures/package.json"], Git::Pkgs::Config.ignored_files
    end
  end

  def test_ecosystems_returns_empty_array_when_not_configured
    Dir.chdir(@test_dir) do
      assert_equal [], Git::Pkgs::Config.ecosystems
    end
  end

  def test_ecosystems_returns_configured_values
    Dir.chdir(@test_dir) do
      system("git config --add pkgs.ecosystems rubygems", out: File::NULL)
      system("git config --add pkgs.ecosystems npm", out: File::NULL)
      Git::Pkgs::Config.reset!

      assert_equal ["rubygems", "npm"], Git::Pkgs::Config.ecosystems
    end
  end

  def test_filter_ecosystem_returns_false_for_local_when_no_ecosystems_configured
    Dir.chdir(@test_dir) do
      refute Git::Pkgs::Config.filter_ecosystem?("rubygems")
      refute Git::Pkgs::Config.filter_ecosystem?("npm")
    end
  end

  def test_filter_ecosystem_returns_true_for_remote_when_no_ecosystems_configured
    Dir.chdir(@test_dir) do
      assert Git::Pkgs::Config.filter_ecosystem?("carthage")
      assert Git::Pkgs::Config.filter_ecosystem?("clojars")
      assert Git::Pkgs::Config.filter_ecosystem?("hackage")
      assert Git::Pkgs::Config.filter_ecosystem?("hex")
      assert Git::Pkgs::Config.filter_ecosystem?("swiftpm")
    end
  end

  def test_filter_ecosystem_allows_remote_when_explicitly_enabled
    Dir.chdir(@test_dir) do
      system("git config --add pkgs.ecosystems carthage", out: File::NULL)
      Git::Pkgs::Config.reset!

      refute Git::Pkgs::Config.filter_ecosystem?("carthage")
    end
  end

  def test_filter_ecosystem_returns_false_for_included_ecosystem
    Dir.chdir(@test_dir) do
      system("git config --add pkgs.ecosystems rubygems", out: File::NULL)
      system("git config --add pkgs.ecosystems npm", out: File::NULL)
      Git::Pkgs::Config.reset!

      refute Git::Pkgs::Config.filter_ecosystem?("rubygems")
      refute Git::Pkgs::Config.filter_ecosystem?("npm")
    end
  end

  def test_filter_ecosystem_returns_true_for_excluded_ecosystem
    Dir.chdir(@test_dir) do
      system("git config --add pkgs.ecosystems rubygems", out: File::NULL)
      Git::Pkgs::Config.reset!

      assert Git::Pkgs::Config.filter_ecosystem?("npm")
      assert Git::Pkgs::Config.filter_ecosystem?("pypi")
    end
  end

  def test_filter_ecosystem_is_case_insensitive
    Dir.chdir(@test_dir) do
      system("git config --add pkgs.ecosystems RubyGems", out: File::NULL)
      Git::Pkgs::Config.reset!

      refute Git::Pkgs::Config.filter_ecosystem?("rubygems")
      refute Git::Pkgs::Config.filter_ecosystem?("RUBYGEMS")
    end
  end

  def test_remote_ecosystem_returns_true_for_remote_ecosystems
    assert Git::Pkgs::Config.remote_ecosystem?("carthage")
    assert Git::Pkgs::Config.remote_ecosystem?("clojars")
    assert Git::Pkgs::Config.remote_ecosystem?("hackage")
    assert Git::Pkgs::Config.remote_ecosystem?("hex")
    assert Git::Pkgs::Config.remote_ecosystem?("swiftpm")
  end

  def test_remote_ecosystem_returns_false_for_local_ecosystems
    refute Git::Pkgs::Config.remote_ecosystem?("rubygems")
    refute Git::Pkgs::Config.remote_ecosystem?("npm")
    refute Git::Pkgs::Config.remote_ecosystem?("pypi")
  end

  def test_configure_bibliothecary_adds_ignored_dirs
    Dir.chdir(@test_dir) do
      system("git config --add pkgs.ignoredDirs my_vendor", out: File::NULL)
      Git::Pkgs::Config.reset!

      original_dirs = Bibliothecary.configuration.ignored_dirs.dup
      Git::Pkgs::Config.configure_bibliothecary

      assert_includes Bibliothecary.configuration.ignored_dirs, "my_vendor"

      # Clean up
      Bibliothecary.configuration.ignored_dirs = original_dirs
    end
  end

  def test_configure_bibliothecary_adds_ignored_files
    Dir.chdir(@test_dir) do
      system("git config --add pkgs.ignoredFiles fixtures/Gemfile", out: File::NULL)
      Git::Pkgs::Config.reset!

      original_files = Bibliothecary.configuration.ignored_files.dup
      Git::Pkgs::Config.configure_bibliothecary

      assert_includes Bibliothecary.configuration.ignored_files, "fixtures/Gemfile"

      # Clean up
      Bibliothecary.configuration.ignored_files = original_files
    end
  end
end
