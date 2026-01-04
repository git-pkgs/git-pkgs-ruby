# Benchmarking

git-pkgs includes benchmark scripts for profiling performance. Run them with:

```bash
bin/benchmark <type> [repo_path] [sample_size]
```

The default repo is `/Users/andrew/code/octobox` and sample size is 500 commits.

## Benchmark Types

### full

Full pipeline benchmark with phase breakdown:

```bash
bin/benchmark full /path/to/repo 500
```

Measures time spent in each phase: git diff extraction, manifest filtering, parsing, and database writes. Reports overall throughput in commits/sec.

### detailed

Granular breakdown of each processing step:

```bash
bin/benchmark detailed /path/to/repo 500
```

Shows timing for blob path extraction, regex pre-filtering, bibliothecary identification, and manifest parsing. Also breaks down parsing time by platform (rubygems, npm, etc.) and reports how many commits pass each filter stage.

### bulk

Compares data collection vs bulk insert performance:

```bash
bin/benchmark bulk /path/to/repo 500
```

Separates the time spent analyzing commits from the time spent writing to the database. Uses `insert_all` for bulk operations. Helps identify whether bottlenecks are in git/parsing or database writes.

### db

Individual database operation timing:

```bash
bin/benchmark db /path/to/repo 200
```

Measures each ActiveRecord operation separately: commit creation, branch_commit creation, manifest lookups, change inserts, and snapshot inserts. Shows per-operation averages in milliseconds.

### commands

End-to-end CLI command benchmarks:

```bash
bin/benchmark commands --repo /path/to/repo -n 3
```

Runs actual git-pkgs commands (`blame`, `stale`, `stats`, `log`, `list`) against a repo with an existing database. Measures wall-clock time over multiple iterations. Useful for regression testing command performance.

The repo must already have a database from `git pkgs init`.

## Interpreting Results

The main bottlenecks are typically:

1. **Git blob reads** - extracting file contents from commits
2. **Bibliothecary parsing** - parsing manifest file contents
3. **Database writes** - inserting records (mitigated by bulk inserts)

The regex pre-filter (`might_have_manifests?`) skips most commits cheaply. On a typical codebase, only 10-20% of commits touch files that could be manifests.

Blob OID caching helps when the same manifest content appears across multiple commits. The cache stats show hit rates.

## Example Output

```
Full pipeline benchmark: 500 commits
============================================================

Full pipeline breakdown:
------------------------------------------------------------
  git_diff           0.892s  (12.3%)
  filtering          0.234s  (3.2%)
  parsing            4.521s  (62.4%)
  db_writes          1.602s  (22.1%)
------------------------------------------------------------
  Total              7.249s

Throughput: 69.0 commits/sec
Cache stats: {:cached_blobs=>142, :blobs_with_hits=>89}
```
