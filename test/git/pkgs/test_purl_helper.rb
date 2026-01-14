# frozen_string_literal: true

require "test_helper"

class Git::Pkgs::TestPurlHelper < Minitest::Test
  def test_purl_type_for_rubygems
    assert_equal "gem", Git::Pkgs::PurlHelper.purl_type_for("rubygems")
  end

  def test_purl_type_for_npm
    assert_equal "npm", Git::Pkgs::PurlHelper.purl_type_for("npm")
  end

  def test_purl_type_for_go
    assert_equal "golang", Git::Pkgs::PurlHelper.purl_type_for("go")
  end

  def test_purl_type_for_packagist
    assert_equal "composer", Git::Pkgs::PurlHelper.purl_type_for("packagist")
  end

  def test_purl_type_for_unknown_falls_back_to_ecosystem
    assert_equal "unknown", Git::Pkgs::PurlHelper.purl_type_for("unknown")
  end

  def test_build_purl_without_version
    purl = Git::Pkgs::PurlHelper.build_purl(ecosystem: "rubygems", name: "rails")
    assert_equal "pkg:gem/rails", purl.to_s
  end

  def test_build_purl_with_version
    purl = Git::Pkgs::PurlHelper.build_purl(ecosystem: "rubygems", name: "rails", version: "7.0.0")
    assert_equal "pkg:gem/rails@7.0.0", purl.to_s
  end

  def test_build_purl_for_npm
    purl = Git::Pkgs::PurlHelper.build_purl(ecosystem: "npm", name: "lodash", version: "4.17.21")
    assert_equal "pkg:npm/lodash@4.17.21", purl.to_s
  end

  def test_build_purl_for_go
    purl = Git::Pkgs::PurlHelper.build_purl(ecosystem: "go", name: "github.com/gorilla/mux", version: "1.8.0")
    assert_equal "golang", purl.type
    assert_equal "github.com/gorilla/mux", purl.name
    assert_equal "1.8.0", purl.version
  end
end
