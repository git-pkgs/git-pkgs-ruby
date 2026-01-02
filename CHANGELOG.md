## [Unreleased]

- `git pkgs show` command to display dependency changes in a single commit

## [0.1.1] - 2026-01-01

- `git pkgs history` now works without a package argument to show all dependency changes
- `git pkgs diff` supports git refs (HEAD~10, branch names, tags) not just SHAs
- `git pkgs diff` lazily inserts commits not found in the database
- Expanded manifest file pattern matching for all supported ecosystems
- Switched to ecosystems-bibliothecary

## [0.1.0] - 2026-01-01

- Initial release
