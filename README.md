# git-pkgs

A git subcommand for tracking package dependencies across git history. Analyzes your repository to show when dependencies were added, modified, or removed, who made those changes, and why.

## Why this exists

Your lockfile shows what dependencies you have. It doesn't show how you got here. `git log Gemfile.lock` is useless noise.

git-pkgs indexes your dependency history into a queryable database. You can ask: when did we add this? who added it? what changed between these two releases? has anyone touched this in the last year?

It works across ecosystems. Gemfile, package.json, Dockerfile, GitHub Actions workflows - one unified history instead of separate tools per ecosystem.

## Installation

```bash
gem install git-pkgs
```

## Quick start

```bash
cd your-repo
git pkgs init           # analyze history (one-time, ~300 commits/sec)
git pkgs list           # show current dependencies
git pkgs stats          # see overview
git pkgs blame          # who added each dependency
git pkgs history        # all dependency changes over time
git pkgs history rails  # track a specific package
git pkgs why rails      # why was this added?
git pkgs diff --from=HEAD~10  # what changed recently?
git pkgs diff --from=main --to=feature  # compare branches
```

## Commands

### Initialize the database

```bash
git pkgs init
```

Walks through git history and builds a SQLite database of dependency changes, stored in `.git/pkgs.sqlite3`.

Options:
- `--branch=NAME` - analyze a specific branch (default: default branch)
- `--since=SHA` - start analysis from a specific commit
- `--force` - rebuild the database from scratch
- `--hooks` - install git hooks for auto-updating

Example output:
```
Analyzing branch: main
Processing commit 5191/5191...
Done!
Analyzed 5191 commits
Found 2531 commits with dependency changes
Stored 28239 snapshots (every 20 changes)
Blob cache: 3141 unique blobs, 2349 had cache hits
```

### Database info

```bash
git pkgs info
```

Shows database size and row counts:

```
Database Info
========================================

Location: /path/to/repo/.git/pkgs.sqlite3
Size: 8.3 MB

Row Counts
----------------------------------------
  Branches                        1
  Commits                      3988
  Branch-Commits               3988
  Manifests                       9
  Dependency Changes           4732
  Dependency Snapshots        28239
  ----------------------------------
  Total                       40957

Snapshot Coverage
----------------------------------------
  Commits with dependency changes: 2531
  Commits with snapshots: 127
  Coverage: 5.0% (1 snapshot per ~20 changes)
```

### List dependencies

```bash
git pkgs list
git pkgs list --commit=abc123
git pkgs list --ecosystem=rubygems
```

Example output:
```
Gemfile (rubygems):
  bootsnap >= 0 [runtime]
  bootstrap = 4.6.2 [runtime]
  bugsnag >= 0 [runtime]
  rails = 8.0.1 [runtime]
  sidekiq >= 0 [runtime]
  ...
```

### View dependency history

```bash
git pkgs history          # all dependency changes
git pkgs history rails    # changes for a specific package
```

Shows when packages were added, updated, or removed:

```
History for rails:

2016-12-16 Added = 5.0.0.1
  Commit: e323669 Hello World
  Author: Andrew Nesbitt <andrew@example.com>
  Manifest: Gemfile

2016-12-21 Updated = 5.0.0.1 -> = 5.0.1
  Commit: 0c70eee Update rails to 5.0.1
  Author: Andrew Nesbitt <andrew@example.com>
  Manifest: Gemfile

2024-11-21 Updated = 7.2.2 -> = 8.0.0
  Commit: 86a07f4 Upgrade to Rails 8
  Author: Andrew Nesbitt <andrew@example.com>
  Manifest: Gemfile
```

### Blame

Show who added each current dependency:

```bash
git pkgs blame
git pkgs blame --ecosystem=rubygems
```

Example output:
```
Gemfile (rubygems):
  bootsnap                        Andrew Nesbitt     2018-04-10  7da4369
  bootstrap                       Andrew Nesbitt     2018-08-02  0b39dc0
  bugsnag                         Andrew Nesbitt     2016-12-23  a87f1bf
  factory_bot                     Lewis Buckley      2017-12-25  f6cceb0
  faraday                         Andrew Nesbitt     2021-11-25  98de229
  jwt                             Andrew Nesbitt     2018-09-10  a39f0ea
  octokit                         Andrew Nesbitt     2016-12-16  e323669
  omniauth-rails_csrf_protection  dependabot[bot]    2021-11-02  02474ab
  rails                           Andrew Nesbitt     2016-12-16  e323669
  sidekiq                         Mark Tareshawty    2018-02-19  29a1c70
```

### Show statistics

```bash
git pkgs stats
```

Example output:
```
Dependency Statistics
========================================

Branch: main
Commits analyzed: 3988
Commits with changes: 2531

Current Dependencies
--------------------
Total: 250
  rubygems: 232
  actions: 14
  docker: 4

Dependency Changes
--------------------
Total changes: 4732
  added: 391
  modified: 4200
  removed: 141

Most Changed Dependencies
-------------------------
  rails (rubygems): 135 changes
  pagy (rubygems): 116 changes
  nokogiri (rubygems): 85 changes
  puma (rubygems): 73 changes

Manifest Files
--------------
  Gemfile (rubygems): 294 changes
  Gemfile.lock (rubygems): 4269 changes
  .github/workflows/ci.yml (actions): 36 changes
```

### Explain why a dependency exists

```bash
git pkgs why rails
```

Shows the commit that added the dependency with author and message.

### Dependency tree

```bash
git pkgs tree
git pkgs tree --ecosystem=rubygems
```

Shows dependencies grouped by type (runtime, development, etc).

### Diff between commits

```bash
git pkgs diff --from=abc123 --to=def456
git pkgs diff --from=HEAD~10
```

Shows added, removed, and modified packages with version info.

### Keep database updated

```bash
git pkgs update
```

Or install git hooks to update automatically after commits and merges:

```bash
git pkgs hooks --install
```

## Performance

Benchmarked on a MacBook Pro analyzing [octobox](https://github.com/octobox/octobox) (5191 commits, 8 years of history): init takes about 18 seconds at roughly 300 commits/sec, producing an 8.3 MB database. About half the commits (2531) had dependency changes.

Optimizations:
- Bulk inserts with transaction batching (100 commits per transaction)
- Blob SHA caching (75% cache hit rate for repeated manifest content)
- Deferred index creation during bulk load
- Sparse snapshots (every 20 dependency-changing commits) for storage efficiency
- SQLite WAL mode for write performance

## Supported ecosystems

git-pkgs uses [ecosystems-bibliothecary](https://github.com/ecosyste-ms/bibliothecary) for parsing, supporting:

Actions, Anaconda, BentoML, Bower, Cargo, CocoaPods, Cog, CPAN, CRAN, CycloneDX, Docker, Dub, DVC, Elm, Go, Haxelib, Homebrew, Julia, Maven, Meteor, MLflow, npm, NuGet, Ollama, Packagist, Pub, PyPI, RubyGems, Shards, SPDX, Vcpkg

## How it works

git-pkgs walks your git history, extracts dependency files at each commit, and diffs them to detect changes. Results are stored in a SQLite database for fast querying.

The database schema stores:
- Commits with dependency changes
- Dependency changes (added/modified/removed) with before/after versions
- Periodic snapshots of full dependency state for efficient point-in-time queries

See [docs/schema.md](docs/schema.md) for full schema documentation.

## Development

```bash
git clone https://github.com/andrew/git-pkgs
cd git-pkgs
bin/setup
rake test
```

## License

AGPL-3.0
