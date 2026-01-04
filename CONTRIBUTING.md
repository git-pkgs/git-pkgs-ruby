# Contributing

## How it works

git-pkgs walks your git history, extracts dependency files at each commit, and diffs them to detect changes. Results are stored in a SQLite database for fast querying.

The database schema stores:
- Commits with dependency changes
- Dependency changes (added/modified/removed) with before/after versions
- Periodic snapshots of full dependency state for efficient point-in-time queries

See the [docs](docs/) folder for architecture details, database schema, and benchmarking tools.

Since the database is just SQLite, you can query it directly for ad-hoc analysis:

```bash
sqlite3 .git/pkgs.sqlite3 "
  SELECT c.author_name, COUNT(*) as deps_added
  FROM dependency_changes dc
  JOIN commits c ON dc.commit_id = c.id
  WHERE dc.change_type = 'added'
  GROUP BY c.author_name
  ORDER BY deps_added DESC
  LIMIT 10;
"
```

## Setup

```bash
git clone https://github.com/andrew/git-pkgs
cd git-pkgs
bin/setup
```

## Running tests

```bash
bundle exec rake test
```

## Pull requests

1. Fork the repo
2. Create a branch
3. Make your changes
4. Run tests
5. Open a PR

## Reporting bugs

Open an issue with steps to reproduce.
