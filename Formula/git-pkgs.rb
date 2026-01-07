class GitPkgs < Formula
  desc "Track package dependencies across git history"
  homepage "https://github.com/andrew/git-pkgs"
  url "https://github.com/andrew/git-pkgs/archive/refs/tags/v0.6.2.tar.gz"
  sha256 "ccd7a8a5b9cb21c52cc488923ed1318387a9fefa4baff2057bd96b27591577aa"
  license "AGPL-3.0"

  depends_on "ruby@4"

  def install
    ENV["GEM_HOME"] = libexec
    system "bundle", "install", "--without", "development"
    system "gem", "build", "git-pkgs.gemspec"
    system "gem", "install", "--ignore-dependencies", "git-pkgs-#{version}.gem"
    bin.install libexec/"bin/git-pkgs"
    bin.env_script_all_files(libexec/"bin", GEM_HOME: ENV.fetch("GEM_HOME", nil))
  end

  test do
    system bin/"git-pkgs", "--version"
  end
end
