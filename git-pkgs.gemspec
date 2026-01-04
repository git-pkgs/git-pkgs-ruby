# frozen_string_literal: true

require_relative "lib/git/pkgs/version"

Gem::Specification.new do |spec|
  spec.name = "git-pkgs"
  spec.version = Git::Pkgs::VERSION
  spec.authors = ["Andrew Nesbitt"]
  spec.email = ["andrewnez@gmail.com"]

  spec.summary = "Track package dependencies across git history"
  spec.description = "A git subcommand for analyzing package/dependency usage in git repositories over time"
  spec.homepage = "https://github.com/andrew/git-pkgs"
  spec.license = "AGPL-3.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["funding_uri"] = "https://github.com/sponsors/andrew"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ docs/ benchmark/]) ||
        f.end_with?(*%w[Rakefile CODE_OF_CONDUCT.md CONTRIBUTING.md SECURITY.md])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "rugged", "~> 1.0"
  spec.add_dependency "activerecord", ">= 7.0"
  spec.add_dependency "sqlite3", ">= 2.0"
  spec.add_dependency "ecosystems-bibliothecary"
end
