# Internals

git-pkgs walks a repository's commit history, parses manifest files at each commit, and stores dependency changes in a SQLite database. This lets you query what changed, when, and who did it.

## Entry Point

The executable at [`exe/git-pkgs`](../exe/git-pkgs) loads [`lib/git/pkgs.rb`](../lib/git/pkgs.rb) and calls `Git::Pkgs::CLI.run`. The [CLI class](../lib/git/pkgs/cli.rb) parses the first argument as a command name and dispatches to the corresponding class in [`lib/git/pkgs/commands/`](../lib/git/pkgs/commands/). Each command handles its own option parsing with [OptionParser](https://docs.ruby-lang.org/en/master/OptionParser.html).

## Database

[`Git::Pkgs::Database`](../lib/git/pkgs/database.rb) manages the SQLite connection using [Sequel](https://sequel.jeremyevans.net/) and [sqlite3](https://github.com/sparklemotion/sqlite3-ruby). It looks for the `GIT_PKGS_DB` environment variable first, then falls back to `.git/pkgs.sqlite3`. Schema migrations are versioned through a `schema_info` table. See [schema.md](schema.md) for the full schema.

The schema has ten tables. Six handle dependency tracking:

- `commits` holds commit metadata plus a flag indicating whether it changed dependencies
- `branches` tracks which branches have been analyzed and their last processed SHA
- `branch_commits` is a join table preserving commit order within each branch
- `manifests` stores file paths with their ecosystem (npm, rubygems, etc.) and kind (manifest vs lockfile)
- `dependency_changes` records every add, modify, or remove event
- `dependency_snapshots` stores full dependency state at intervals

Four more support vulnerability scanning and package enrichment:

- `packages` tracks package metadata, vulnerability sync status, and enrichment data
- `versions` stores per-version metadata (license, published date) for time-travel queries
- `vulnerabilities` caches CVE/GHSA data fetched from OSV
- `vulnerability_packages` maps which packages are affected by each vulnerability

Snapshots exist because replaying thousands of change records to answer "what dependencies existed at commit X?" would be slow. Instead, we store the complete dependency set every 50 commits by default. Point-in-time queries find the nearest snapshot and replay only the changes since then.

## Git Access

[`Git::Pkgs::Repository`](../lib/git/pkgs/repository.rb) wraps [rugged](https://github.com/libgit2/rugged) (Ruby bindings for [libgit2](https://libgit2.org/)) for git operations. The `walk` method yields commits in topological order. `blob_paths` returns changed files for a commit. `content_at_commit` and `blob_oid_at_commit` fetch file contents and their object IDs. The OID matters for caching: if two commits have the same blob OID for a file, we don't parse it twice.

For large repositories, `prefetch_blob_paths` computes diffs in parallel using multiple threads. This provides roughly 2x speedup on git operations for repos with 1500+ commits. Smaller repos use serial processing because thread creation and mutex synchronization overhead exceeds any parallel gains.

## Manifest Analysis

[`Git::Pkgs::Analyzer`](../lib/git/pkgs/analyzer.rb) does the actual work of detecting and parsing manifests. It uses the [ecosystems-bibliothecary](https://github.com/ecosyste-ms/bibliothecary) gem, which supports 30+ package managers. Bibliothecary is expensive to call, so the analyzer has a `QUICK_MANIFEST_PATTERNS` regex that filters files before attempting real parsing. This cuts out most commits that touch only source code.

The `analyze_commit` method compares the manifest state before and after a commit:

```ruby
added = after_deps.keys - before_deps.keys
removed = before_deps.keys - after_deps.keys
modified = common.select { |k| before_deps[k][:requirement] != after_deps[k][:requirement] }
```

Merge commits get skipped entirely. They don't introduce new changes, just incorporate parent histories.

## The Init Process

When you run `git pkgs init` (see [`commands/init.rb`](../lib/git/pkgs/commands/init.rb)):

1. Creates the database schema
2. Switches to bulk write mode (WAL, synchronous off, large cache)
3. Loads all commits and prefetches git diffs in parallel
4. For each commit with manifest changes, calls `analyzer.analyze_commit`
5. Batches inserts in transactions of 500 commits
6. Creates dependency snapshots every 50 commits that changed dependencies
7. Creates indexes after all data is loaded
8. Switches back to normal sync mode

Deferring index creation until the end speeds things up considerably. Batch size, snapshot interval, and thread count are configurable via environment variables (see Performance Notes below).

## Incremental Updates

[`git pkgs update`](../lib/git/pkgs/commands/update.rb) picks up where init left off. Each branch stores its `last_analyzed_sha`. Update walks from that commit to HEAD, processes new commits one at a time, and advances the checkpoint. This makes daily usage fast even on large repositories.

## Schema Upgrades

The database stores its schema version in the `schema_info` table. When git-pkgs is updated and the schema changes, commands detect the mismatch and prompt you to run `git pkgs upgrade`.

The [`upgrade` command](../lib/git/pkgs/commands/upgrade.rb) takes a simple approach: it compares `Database.stored_version` against `Database::SCHEMA_VERSION` and, if they differ, runs `init --force` to rebuild from scratch. There are no incremental migrations. This keeps the code simple at the cost of requiring a full re-index when the schema changes.

## Lazy Commit Insertion

The [`diff` command](../lib/git/pkgs/commands/diff.rb) can compare commits that aren't in the database yet. When you run `git pkgs diff --from=origin/main`, the command resolves the ref to a SHA and calls `Commit.find_or_create_from_repo`. If the commit doesn't exist, it gets created on the fly with its metadata.

This means you can diff against any commit in the repository without having analyzed it first. The trade-off is that lazy-inserted commits won't have dependency change data, only their metadata. For full change tracking, run `git pkgs update` to process new commits properly.

## Git Hooks

The [`hooks` command](../lib/git/pkgs/commands/hooks.rb) installs shell scripts into `.git/hooks/` that run `git pkgs update` after commits and merges. Init installs these by default.

Two hooks are managed: `post-commit` and `post-merge`. If a hook file already exists, the command appends the update call rather than replacing the file. Uninstall reverses this, removing the git-pkgs lines or deleting the hook file if nothing else remains.

The hook script is minimal:

```sh
#!/bin/sh
git pkgs update 2>/dev/null || true
```

Errors are suppressed so a failed update doesn't block normal git operations.

## Diff Driver

The [`diff-driver` command](../lib/git/pkgs/commands/diff_driver.rb) sets up a git [textconv](https://git-scm.com/docs/gitattributes#_performing_text_diffs_of_binary_files) filter that transforms lockfiles before diffing. Instead of seeing raw lockfile churn, `git diff` shows a sorted list of dependencies with versions.

Installation does two things:

1. Sets `diff.pkgs.textconv` in git config to invoke `git-pkgs diff-driver`
2. Adds patterns to `.gitattributes` mapping lockfiles to this driver

When git diffs a lockfile, it calls `git-pkgs diff-driver <path>` on each version. The command parses the file with bibliothecary and outputs one line per dependency: `name version [type]`. Git then diffs these text representations instead of the raw files.

Only lockfiles get this treatment. Manifests like Gemfile or package.json are human-readable and diff fine on their own. The `LOCKFILE_PATTERNS` constant lists supported filenames.

## Point-in-Time Reconstruction

Several commands need to know the full dependency set at a specific commit. The [`list` command](../lib/git/pkgs/commands/list.rb) shows this directly; `blame`, `stats`, and others use it internally.

The algorithm:

1. Find the latest snapshot at or before the target commit
2. Load that snapshot as the initial state
3. Query changes between the snapshot and target, ordered by `committed_at`
4. Apply each change: added/modified updates the hash, removed deletes the key

Ordering by `committed_at` instead of git topology is a simplification that works well in practice. The committed timestamp reflects when the commit actually entered the branch.

## Author Detection

The [`blame` command](../lib/git/pkgs/commands/blame.rb) attributes each dependency to whoever added it. It parses Co-Authored-By trailers from commit messages and prefers human authors over bots. Bot detection looks for the `[bot]` suffix plus known names like dependabot and renovate.

## Working Directory Queries

Most commands query the database exclusively. The [`where` command](../lib/git/pkgs/commands/where.rb) is different: it uses the database to find which manifests contain a package, then reads the actual files from the working directory to show exact line numbers.

This hybrid approach means `where` shows current file contents rather than historical state. If you've modified a manifest but haven't committed, `where` reflects those changes. The database just narrows down which files to search.

## Output Handling

[`Git::Pkgs::Output`](../lib/git/pkgs/output.rb) provides helpers for errors and empty results. [`Git::Pkgs::Pager`](../lib/git/pkgs/pager.rb) follows git's pager precedence: `GIT_PAGER`, then `core.pager` config, then `PAGER` environment variable, then `less`. It disables itself when not connected to a TTY. [`Git::Pkgs::Color`](../lib/git/pkgs/color.rb) respects `NO_COLOR` and the `color.pkgs` git config setting.

## Adding Commands

Create a new file in [`lib/git/pkgs/commands/`](../lib/git/pkgs/commands/). Define `self.description` for help text and `self.run(args)` as the entry point. The CLI finds commands by constantizing the argument.

## Vulnerability Scanning

The [`vulns` command](../lib/git/pkgs/commands/vulns.rb) checks dependencies against the [OSV database](https://osv.dev). Three additional tables support this:

- `packages` tracks which packages have been checked and when
- `vulnerabilities` caches CVE/GHSA metadata (severity, summary, dates)
- `vulnerability_packages` maps which packages are affected by each vulnerability

### OSV Client

[`Git::Pkgs::OsvClient`](../lib/git/pkgs/osv_client.rb) wraps the OSV REST API. It uses batch queries (`/querybatch`) to check up to 1000 packages per request, then fetches full details for each vulnerability found (`/vulns/{id}`). HTTP connections are reused across requests.

### Ecosystem Mapping

OSV uses different ecosystem names than bibliothecary. [`Git::Pkgs::Ecosystems`](../lib/git/pkgs/ecosystems.rb) translates between them:

| bibliothecary | OSV | purl |
|---------------|-----|------|
| rubygems | RubyGems | gem |
| npm | npm | npm |
| pypi | PyPI | pypi |
| cargo | crates.io | cargo |
| go | Go | golang |
| maven | Maven | maven |
| nuget | NuGet | nuget |
| packagist | Packagist | composer |
| hex | Hex | hex |
| pub | Pub | pub |

Only these ecosystems support vulnerability scanning. Others (Docker, Actions, etc.) are tracked for dependency history but have no OSV coverage.

### Version Matching

[`VulnerabilityPackage#affects_version?`](../lib/git/pkgs/models/vulnerability_package.rb) uses the [vers](https://github.com/package-url/vers) gem to check if a version falls within an affected range. OSV returns ranges like `>=1.0.0 <2.0.0` or `<4.17.21`. The vers gem handles semver comparison across different ecosystems.

Version ranges can have multiple OR conditions separated by `||`. Each condition is checked independently: `<1.0 || >=2.0 <3.0` means "affected if below 1.0 OR between 2.0 and 3.0".

### Caching

Vulnerability data is cached in the database to avoid repeated API calls. Each package in the `packages` table has a `vulns_synced_at` timestamp. Packages are refreshed if their data is more than 24 hours old. The `vulns sync --refresh` command forces a full refresh.

When scanning, git-pkgs:

1. Gets dependencies at the target commit (from snapshots or by parsing manifests)
2. Filters to ecosystems with OSV support
3. Checks which packages need syncing (never synced or stale)
4. Batch queries OSV for those packages
5. Fetches full vulnerability details for any new CVEs found
6. Matches version ranges against actual versions
7. Excludes withdrawn vulnerabilities

## Package Enrichment

The [`outdated`](../lib/git/pkgs/commands/outdated.rb) and [`licenses`](../lib/git/pkgs/commands/licenses.rb) commands fetch package metadata from the [ecosyste.ms Packages API](https://packages.ecosyste.ms/).

### Ecosystems Client

[`Git::Pkgs::EcosystemsClient`](../lib/git/pkgs/ecosystems_client.rb) wraps the ecosyste.ms REST API. It uses batch lookups (`POST /api/v1/packages/lookup`) to check up to 100 packages per request. The response includes latest version, license, description, and repository URL for each package.

### Enrichment Caching

Like vulnerability data, enrichment data is cached in the database. The `packages` table has an `enriched_at` timestamp. Packages are refreshed if their data is more than 24 hours old. The `Package#needs_enrichment?` method checks this threshold.

When running `outdated` or `licenses`:

1. Get dependencies at the target commit
2. Find or create package records for each purl
3. Check which packages need enrichment (never enriched or stale)
4. Batch query ecosyste.ms for those packages
5. Store the enrichment data via `Package#enrich_from_api`
6. Use the cached data for version comparison or license checking

### Version Comparison

The `outdated` command classifies updates as major, minor, or patch by comparing semver components. It handles the `v` prefix common in some ecosystems and pads partial versions (e.g., "1.2" becomes "1.2.0"). Updates are color-coded: red for major, yellow for minor, cyan for patch.

### License Compliance

The `licenses` command checks licenses against configured policies:

- `--permissive` only allows common permissive licenses (MIT, Apache-2.0, BSD variants)
- `--copyleft` flags GPL, AGPL, and similar licenses
- `--allow` and `--deny` let you specify explicit lists
- `--unknown` flags packages with no license information

The command exits with code 1 when violations are found, making it suitable for CI pipelines.

## Models

Sequel models live in [`lib/git/pkgs/models/`](../lib/git/pkgs/models/). They're straightforward except for a few convenience methods:

- `Commit.find_or_create_from_repo(repository, sha)` handles partial SHA resolution
- `Manifest.find_or_create(path, ecosystem, kind)` uses a cache to avoid repeated lookups during init
- `DependencyChange` has scopes like `.added`, `.for_package(name)`, `.for_platform(ecosystem)`

## Performance Notes

Typical init speed is around 75-300 commits per second depending on the repository. The main bottlenecks are git blob reads and bibliothecary parsing. The blob OID cache helps a lot: if a Gemfile hasn't changed in 50 commits, we parse it once and reuse the result. The manifest path regex filter also helps by skipping commits that only touch source files.

For repositories with long histories, the database file can grow to tens of megabytes. The periodic snapshots trade storage for query speed. Three environment variables let you tune performance:

- `GIT_PKGS_BATCH_SIZE` - Number of commits per database transaction (default: 500). Larger batches reduce transaction overhead but use more memory.
- `GIT_PKGS_SNAPSHOT_INTERVAL` - Store full dependency state every N commits with changes (default: 50). Lower values speed up point-in-time queries but increase database size.
- `GIT_PKGS_THREADS` - Number of threads for parallel git diff prefetching (default: 4). Set to 1 to disable parallelism. On large repositories (1500+ commits), parallel prefetching provides roughly 2x speedup on git operations.
