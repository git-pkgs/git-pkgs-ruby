class GitPkgs < Formula
  desc "Track package dependencies across git history"
  homepage "https://github.com/andrew/git-pkgs"
  url "https://github.com/andrew/git-pkgs/archive/refs/tags/v0.7.0.tar.gz"
  sha256 "5c5aebf75e9570945b324777e5fa33cd5e35d31f6172c2415a4bd91db02477cc"
  license "AGPL-3.0"

  depends_on "cmake" => :build
  depends_on "pkg-config" => :build
  depends_on "libgit2"
  depends_on "ruby"

  def install
    ENV["GEM_HOME"] = libexec

    system "git", "init"
    system "git", "add", "."

    system "gem", "build", "git-pkgs.gemspec"
    system "gem", "install", "--no-document", "git-pkgs-#{version}.gem"
    bin.install libexec/"bin/git-pkgs"
    bin.env_script_all_files(libexec/"bin", GEM_HOME: ENV.fetch("GEM_HOME", nil))
  end

  test do
    system bin/"git-pkgs", "--version"
  end
end
