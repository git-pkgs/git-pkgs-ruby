# frozen_string_literal: true

require "test_helper"

class Git::Pkgs::TestEcosystems < Minitest::Test
  def test_to_osv_npm
    assert_equal "npm", Git::Pkgs::Ecosystems.to_osv("npm")
  end

  def test_to_osv_rubygems
    assert_equal "RubyGems", Git::Pkgs::Ecosystems.to_osv("rubygems")
  end

  def test_to_osv_pypi
    assert_equal "PyPI", Git::Pkgs::Ecosystems.to_osv("pypi")
  end

  def test_to_osv_cargo
    assert_equal "crates.io", Git::Pkgs::Ecosystems.to_osv("cargo")
  end

  def test_to_osv_go
    assert_equal "Go", Git::Pkgs::Ecosystems.to_osv("go")
  end

  def test_to_osv_packagist
    assert_equal "Packagist", Git::Pkgs::Ecosystems.to_osv("packagist")
  end

  def test_to_osv_case_insensitive
    assert_equal "RubyGems", Git::Pkgs::Ecosystems.to_osv("RubyGems")
    assert_equal "RubyGems", Git::Pkgs::Ecosystems.to_osv("RUBYGEMS")
  end

  def test_to_osv_unknown_returns_nil
    assert_nil Git::Pkgs::Ecosystems.to_osv("unknown")
  end

  def test_to_purl_rubygems
    assert_equal "gem", Git::Pkgs::Ecosystems.to_purl("rubygems")
  end

  def test_to_purl_packagist
    assert_equal "composer", Git::Pkgs::Ecosystems.to_purl("packagist")
  end

  def test_to_purl_go
    assert_equal "golang", Git::Pkgs::Ecosystems.to_purl("go")
  end

  def test_from_osv_rubygems
    assert_equal "rubygems", Git::Pkgs::Ecosystems.from_osv("RubyGems")
  end

  def test_from_osv_crates
    assert_equal "cargo", Git::Pkgs::Ecosystems.from_osv("crates.io")
  end

  def test_from_purl_gem
    assert_equal "rubygems", Git::Pkgs::Ecosystems.from_purl("gem")
  end

  def test_from_purl_golang
    assert_equal "go", Git::Pkgs::Ecosystems.from_purl("golang")
  end

  def test_supported_rubygems
    assert Git::Pkgs::Ecosystems.supported?("rubygems")
  end

  def test_supported_npm
    assert Git::Pkgs::Ecosystems.supported?("npm")
  end

  def test_supported_unknown
    refute Git::Pkgs::Ecosystems.supported?("unknown")
  end

  def test_supported_ecosystems_list
    ecosystems = Git::Pkgs::Ecosystems.supported_ecosystems
    assert_includes ecosystems, "npm"
    assert_includes ecosystems, "rubygems"
    assert_includes ecosystems, "pypi"
    assert_includes ecosystems, "cargo"
    assert_includes ecosystems, "maven"
  end

  def test_generate_purl_npm
    assert_equal "pkg:npm/lodash", Git::Pkgs::Ecosystems.generate_purl("npm", "lodash")
  end

  def test_generate_purl_rubygems
    assert_equal "pkg:gem/rails", Git::Pkgs::Ecosystems.generate_purl("rubygems", "rails")
  end

  def test_generate_purl_pypi
    assert_equal "pkg:pypi/requests", Git::Pkgs::Ecosystems.generate_purl("pypi", "requests")
  end

  def test_generate_purl_cargo
    assert_equal "pkg:cargo/serde", Git::Pkgs::Ecosystems.generate_purl("cargo", "serde")
  end

  def test_generate_purl_go
    assert_equal "pkg:golang/github.com/gin-gonic/gin", Git::Pkgs::Ecosystems.generate_purl("go", "github.com/gin-gonic/gin")
  end

  def test_generate_purl_unknown_ecosystem
    assert_nil Git::Pkgs::Ecosystems.generate_purl("unknown", "package")
  end
end
