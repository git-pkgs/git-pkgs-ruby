## [Unreleased]

- `git pkgs stats` now supports `--since` and `--until` date filters
- Consistent error handling across all commands (JSON errors when `--format=json`)
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
