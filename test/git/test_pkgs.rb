# frozen_string_literal: true

require "test_helper"

class Git::TestPkgs < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::Git::Pkgs::VERSION
  end
end

class Git::TestPkgsStatelessAPI < Minitest::Test
  def test_parse_file_gemfile
    content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails", "~> 7.0"
      gem "puma"
    GEMFILE

    result = Git::Pkgs.parse_file("Gemfile", content)

    assert_equal "rubygems", result[:platform]
    assert_equal "manifest", result[:kind]
    assert_equal 2, result[:dependencies].length

    rails = result[:dependencies].find { |d| d[:name] == "rails" }
    assert_equal "~> 7.0", rails[:requirement]
  end

  def test_parse_file_package_json
    content = JSON.generate({
      "name" => "test",
      "dependencies" => { "lodash" => "^4.0.0" },
      "devDependencies" => { "jest" => "^29.0.0" }
    })

    result = Git::Pkgs.parse_file("package.json", content)

    assert_equal "npm", result[:platform]
    assert_equal 2, result[:dependencies].length

    lodash = result[:dependencies].find { |d| d[:name] == "lodash" }
    assert_equal "^4.0.0", lodash[:requirement]
    assert_equal "runtime", lodash[:type]

    jest = result[:dependencies].find { |d| d[:name] == "jest" }
    assert_equal "development", jest[:type]
  end

  def test_parse_file_returns_nil_for_unknown_files
    result = Git::Pkgs.parse_file("README.md", "# Hello")
    assert_nil result
  end

  def test_parse_file_returns_nil_for_filtered_ecosystem
    Git::Pkgs::Config.configure_bibliothecary
    # Save original and set ecosystems filter via instance variable
    original = Git::Pkgs::Config.instance_variable_get(:@ecosystems)
    Git::Pkgs::Config.instance_variable_set(:@ecosystems, ["npm"])

    content = 'source "https://rubygems.org"'
    result = Git::Pkgs.parse_file("Gemfile", content)

    assert_nil result
  ensure
    Git::Pkgs::Config.instance_variable_set(:@ecosystems, original)
  end

  def test_parse_files_multiple
    files = {
      "Gemfile" => 'source "https://rubygems.org"\ngem "rails"',
      "package.json" => '{"name": "test", "dependencies": {"lodash": "^4.0"}}',
      "README.md" => "# Not a manifest"
    }

    results = Git::Pkgs.parse_files(files)

    assert_equal 2, results.length
    platforms = results.map { |r| r[:platform] }
    assert_includes platforms, "rubygems"
    assert_includes platforms, "npm"
  end

  def test_parse_files_empty_when_no_manifests
    files = {
      "README.md" => "# Hello",
      "src/main.rb" => "puts 'hello'"
    }

    results = Git::Pkgs.parse_files(files)
    assert_equal [], results
  end

  def test_diff_file_added_dependencies
    old_content = ""
    new_content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails"
      gem "puma"
    GEMFILE

    result = Git::Pkgs.diff_file("Gemfile", old_content, new_content)

    assert_equal "Gemfile", result[:path]
    assert_equal "rubygems", result[:platform]
    assert_equal 2, result[:added].length
    assert_equal [], result[:modified]
    assert_equal [], result[:removed]

    names = result[:added].map { |d| d[:name] }
    assert_includes names, "rails"
    assert_includes names, "puma"
  end

  def test_diff_file_removed_dependencies
    old_content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails"
      gem "puma"
    GEMFILE
    new_content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails"
    GEMFILE

    result = Git::Pkgs.diff_file("Gemfile", old_content, new_content)

    assert_equal [], result[:added]
    assert_equal [], result[:modified]
    assert_equal 1, result[:removed].length
    assert_equal "puma", result[:removed].first[:name]
  end

  def test_diff_file_modified_dependencies
    old_content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails", "~> 6.0"
    GEMFILE
    new_content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails", "~> 7.0"
    GEMFILE

    result = Git::Pkgs.diff_file("Gemfile", old_content, new_content)

    assert_equal [], result[:added]
    assert_equal 1, result[:modified].length
    assert_equal [], result[:removed]

    modified = result[:modified].first
    assert_equal "rails", modified[:name]
    assert_equal "~> 7.0", modified[:requirement]
    assert_equal "~> 6.0", modified[:previous_requirement]
  end

  def test_diff_file_mixed_changes
    old_content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails", "~> 6.0"
      gem "sidekiq"
    GEMFILE
    new_content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails", "~> 7.0"
      gem "puma"
    GEMFILE

    result = Git::Pkgs.diff_file("Gemfile", old_content, new_content)

    assert_equal 1, result[:added].length
    assert_equal "puma", result[:added].first[:name]

    assert_equal 1, result[:modified].length
    assert_equal "rails", result[:modified].first[:name]

    assert_equal 1, result[:removed].length
    assert_equal "sidekiq", result[:removed].first[:name]
  end

  def test_diff_file_deleted_file
    old_content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails"
    GEMFILE
    new_content = ""

    result = Git::Pkgs.diff_file("Gemfile", old_content, new_content)

    assert_equal [], result[:added]
    assert_equal [], result[:modified]
    assert_equal 1, result[:removed].length
    assert_equal "rails", result[:removed].first[:name]
  end

  def test_diff_file_returns_nil_for_unknown_files
    result = Git::Pkgs.diff_file("README.md", "# Old", "# New")
    assert_nil result
  end

  def test_diff_file_no_changes
    content = <<~GEMFILE
      source "https://rubygems.org"
      gem "rails", "~> 7.0"
    GEMFILE

    result = Git::Pkgs.diff_file("Gemfile", content, content)

    assert_equal [], result[:added]
    assert_equal [], result[:modified]
    assert_equal [], result[:removed]
  end
end
