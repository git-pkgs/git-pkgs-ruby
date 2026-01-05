## [Unreleased]

## [0.6.1] - 2026-01-05

- Fix `stats` command crash on most changed dependencies query

## [0.6.0] - 2026-01-05

- Replace ActiveRecord with Sequel (~3x faster init, ~2x faster queries)
- `git pkgs stats` now shows top authors in default output
- Update ecosystems-bibliothecary to ~> 15.0 (~10x faster lockfile parsing)
- Fewer runtime dependencies
- Quieter output from `init` and `update` commands

## [0.5.0] - 2026-01-04

- `git pkgs init` now installs git hooks by default (use `--no-hooks` to skip)
- Parallel prefetching of git diffs for ~2x speedup on large repositories (1500+ commits)
- Performance tuning via environment variables: `GIT_PKGS_BATCH_SIZE`, `GIT_PKGS_SNAPSHOT_INTERVAL`, `GIT_PKGS_THREADS`
- `git pkgs completions` command for bash/zsh tab completion
- Fix N+1 queries in `blame`, `stale`, `stats`, and `log` commands
- Configuration via git config: `pkgs.ecosystems`, `pkgs.ignoredDirs`, `pkgs.ignoredFiles`
- `git pkgs info --ecosystems` to show available ecosystems and their status
- `-q, --quiet` flag to suppress informational messages
- `git pkgs diff` now supports `commit..commit` range syntax
- `--git-dir` and `--work-tree` global options (also respects `GIT_WORK_TREE` env var)
- Grouped commands by category in help output
- Fix crash when parsing manifests that return no dependencies

## [0.4.0] - 2026-01-04

- `git pkgs where` command to find where a package is declared in manifest files
- `git pkgs diff-driver` command for semantic lockfile diffs in `git diff`
- Ruby 4.0 support
- Fix branch name retrieval and final snapshot storage in `git pkgs init`
- Fix `git pkgs info` snapshot coverage output when zero snapshots
- Fix manifest file pattern matching for wildcard characters
- Fix co-author name parsing in `git pkgs blame`

## [0.3.0] - 2026-01-03

- Pager support for long output (respects `GIT_PAGER`, `core.pager`, `PAGER`)
- `--no-pager` option for commands with long output
- Colored output (respects `NO_COLOR`, `color.ui`, `color.pkgs`)
- `GIT_DIR` and `GIT_PKGS_DB` environment variable support
- `git pkgs stats` now supports `--since` and `--until` date filters
- Consistent error handling across all commands (JSON errors when `--format=json`)
- `git pkgs update` now uses a transaction for atomicity and better performance
- Renamed `git pkgs outdated` to `git pkgs stale` (outdated remains as alias)
- `git pkgs log` command to list commits with dependency changes
- `git pkgs schema` command to output database schema in text, SQL, JSON, or markdown
- `git pkgs praise` alias for `blame`
- `git pkgs upgrade` command to handle schema upgrades after updating git-pkgs
- Schema version tracking with automatic detection of outdated databases

## [0.2.0] - 2026-01-02

- `git pkgs show` command to display dependency changes in a single commit
- `git pkgs history` now supports `--author`, `--since`, and `--until` filters
- `git pkgs stats --by-author` shows who added the most dependencies
- `git pkgs stats --ecosystem=X` filters statistics by ecosystem

## [0.1.1] - 2026-01-01

- `git pkgs history` now works without a package argument to show all dependency changes
- `git pkgs diff` supports git refs (HEAD~10, branch names, tags) not just SHAs
- `git pkgs diff` lazily inserts commits not found in the database
- Expanded manifest file pattern matching for all supported ecosystems
- Switched to ecosystems-bibliothecary

## [0.1.0] - 2026-01-01

- Initial release
