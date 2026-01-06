# frozen_string_literal: true

require "test_helper"
require "stringio"
require "tmpdir"

class Git::Pkgs::TestCompletionsCommand < Minitest::Test
  def test_bash_output
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["bash"]).run
    end

    assert_includes output, "_git_pkgs()"
    assert_includes output, "COMPREPLY"
    assert_includes output, "compgen"
    assert_includes output, "complete -F _git_pkgs git-pkgs"
  end

  def test_zsh_output
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["zsh"]).run
    end

    assert_includes output, "#compdef git-pkgs"
    assert_includes output, "_git-pkgs()"
    assert_includes output, "_describe"
    assert_includes output, "_arguments"
  end

  def test_help_output
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["--help"]).run
    end

    assert_includes output, "Usage: git pkgs completions"
    assert_includes output, "bash"
    assert_includes output, "zsh"
    assert_includes output, "install"
  end

  def test_no_args_shows_help
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new([]).run
    end

    assert_includes output, "Usage: git pkgs completions"
  end

  def test_unknown_shell_exits_with_error
    assert_raises(SystemExit) do
      capture_stderr do
        Git::Pkgs::Commands::Completions.new(["fish"]).run
      end
    end
  end

  def test_bash_includes_all_commands
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["bash"]).run
    end

    # Check that main commands are included
    assert_includes output, "init"
    assert_includes output, "update"
    assert_includes output, "history"
    assert_includes output, "completions"
  end

  def test_zsh_includes_all_commands
    output = capture_stdout do
      Git::Pkgs::Commands::Completions.new(["zsh"]).run
    end

    assert_includes output, "'init:Initialize the package database'"
    assert_includes output, "'completions:Generate shell completions'"
  end

  def test_install_creates_bash_completions
    Dir.mktmpdir do |tmpdir|
      ENV["HOME"] = tmpdir
      ENV["SHELL"] = "/bin/bash"

      output = capture_stdout do
        Git::Pkgs::Commands::Completions.new(["install"]).run
      end

      completion_file = File.join(tmpdir, ".local/share/bash-completion/completions/git-pkgs")
      assert File.exist?(completion_file), "Completion file should exist"
      assert_includes File.read(completion_file), "_git_pkgs()"
      assert_includes output, "Installed bash completions"
    end
  ensure
    ENV["HOME"] = Dir.home
    ENV.delete("SHELL")
  end

  def test_install_creates_zsh_completions
    Dir.mktmpdir do |tmpdir|
      ENV["HOME"] = tmpdir
      ENV["SHELL"] = "/bin/zsh"

      output = capture_stdout do
        Git::Pkgs::Commands::Completions.new(["install"]).run
      end

      completion_file = File.join(tmpdir, ".zsh/completions/_git-pkgs")
      assert File.exist?(completion_file), "Completion file should exist"
      assert_includes File.read(completion_file), "#compdef git-pkgs"
      assert_includes output, "Installed zsh completions"
    end
  ensure
    ENV["HOME"] = Dir.home
    ENV.delete("SHELL")
  end

end
