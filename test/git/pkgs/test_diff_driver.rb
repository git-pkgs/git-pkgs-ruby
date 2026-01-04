# frozen_string_literal: true

require "test_helper"
require "tempfile"

class Git::Pkgs::TestDiffDriver < Minitest::Test
  def test_outputs_sorted_dependency_list
    content = <<~GEMFILE_LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rails (7.0.0)
          puma (5.0.0)
          sidekiq (6.0.0)

      DEPENDENCIES
        rails
        puma
        sidekiq
    GEMFILE_LOCK

    output = run_textconv(content, "Gemfile.lock")

    lines = output.strip.split("\n")
    assert_equal 3, lines.count
    assert_equal "puma 5.0.0", lines[0]
    assert_equal "rails 7.0.0", lines[1]
    assert_equal "sidekiq 6.0.0", lines[2]
  end

  def test_handles_empty_file
    output = run_textconv("", "Gemfile.lock")
    assert_empty output.strip
  end

  def test_handles_package_lock_json
    content = <<~JSON
      {
        "name": "test",
        "lockfileVersion": 2,
        "packages": {
          "": {
            "dependencies": {
              "react": "^18.0.0",
              "lodash": "^4.0.0"
            }
          },
          "node_modules/react": {
            "version": "18.2.0"
          },
          "node_modules/lodash": {
            "version": "4.17.21"
          }
        }
      }
    JSON

    output = run_textconv(content, "package-lock.json")

    # Should have dependencies listed
    refute_empty output.strip
  end

  def test_handles_invalid_content
    output = run_textconv("not a valid lockfile", "Gemfile.lock")
    assert_empty output.strip
  end

  def test_shows_type_for_non_runtime_dependencies
    content = <<~GEMFILE_LOCK
      GEM
        remote: https://rubygems.org/
        specs:
          rails (7.0.0)
          rspec (3.0.0)

      DEPENDENCIES
        rails
        rspec

      PLATFORMS
        ruby

      BUNDLED WITH
        2.4.0
    GEMFILE_LOCK

    output = run_textconv(content, "Gemfile.lock")

    lines = output.strip.split("\n")
    assert_equal 3, lines.count
    # Bundler is extracted from BUNDLED WITH section
    assert_equal "bundler 2.4.0", lines[0]
    assert_equal "rails 7.0.0", lines[1]
    assert_equal "rspec 3.0.0", lines[2]
  end

  def run_textconv(content, filename)
    # Create temp directory with properly named file so Bibliothecary can identify it
    dir = Dir.mktmpdir
    file_path = File.join(dir, filename)

    begin
      File.write(file_path, content)

      output = StringIO.new
      original_stdout = $stdout
      $stdout = output

      begin
        # Simulate how git calls textconv - with just the file path
        driver = Git::Pkgs::Commands::DiffDriver.new([file_path])
        driver.run
      ensure
        $stdout = original_stdout
      end

      output.string
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

class Git::Pkgs::TestDiffDriverInstall < Minitest::Test
  include TestHelpers

  def setup
    create_test_repo
  end

  def teardown
    cleanup_test_repo
  end

  def test_install_creates_gitattributes_for_lockfiles
    Dir.chdir(@test_dir) do
      capture_stdout do
        driver = Git::Pkgs::Commands::DiffDriver.new(["--install"])
        driver.run
      end

      assert File.exist?(".gitattributes")
      content = File.read(".gitattributes")
      assert_includes content, "Gemfile.lock diff=pkgs"
      assert_includes content, "package-lock.json diff=pkgs"
      assert_includes content, "yarn.lock diff=pkgs"
      # Should NOT include manifests
      refute_includes content, "Gemfile diff=pkgs"
      refute_includes content, "package.json diff=pkgs"
    end
  end

  def test_install_sets_textconv_config
    Dir.chdir(@test_dir) do
      capture_stdout do
        driver = Git::Pkgs::Commands::DiffDriver.new(["--install"])
        driver.run
      end

      config = `git config --get diff.pkgs.textconv`.chomp
      assert_equal "git-pkgs diff-driver", config
    end
  end

  def test_uninstall_removes_config
    Dir.chdir(@test_dir) do
      # First install
      capture_stdout do
        Git::Pkgs::Commands::DiffDriver.new(["--install"]).run
      end

      # Then uninstall
      capture_stdout do
        Git::Pkgs::Commands::DiffDriver.new(["--uninstall"]).run
      end

      config = `git config --get diff.pkgs.textconv 2>&1`.chomp
      refute_equal "git-pkgs diff-driver", config
    end
  end

  def test_uninstall_cleans_gitattributes
    Dir.chdir(@test_dir) do
      # First install
      capture_stdout do
        Git::Pkgs::Commands::DiffDriver.new(["--install"]).run
      end

      # Then uninstall
      capture_stdout do
        Git::Pkgs::Commands::DiffDriver.new(["--uninstall"]).run
      end

      content = File.read(".gitattributes")
      refute_includes content, "diff=pkgs"
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
