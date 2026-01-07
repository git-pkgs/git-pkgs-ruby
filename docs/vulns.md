# Vulnerability Scanning

git-pkgs can scan your dependencies for known vulnerabilities using the OSV (Open Source Vulnerabilities) database. Because git-pkgs already tracks the full history of every dependency change, it can provide context that static scanners can't: who introduced a vulnerability, when, and why.

## Basic Usage

Scan dependencies at HEAD:

```
$ git pkgs vulns
CRITICAL  CVE-2024-1234  lodash 4.17.15  (fixed in 4.17.21)
HIGH      GHSA-xxxx     express 4.18.0  (fixed in 4.18.2)
```

Scan at a specific commit, tag, or branch:

```
$ git pkgs vulns v1.0.0
$ git pkgs vulns abc1234
$ git pkgs vulns HEAD~10
$ git pkgs vulns main
```

## Options

```
-e, --ecosystem=NAME    Filter by ecosystem (npm, rubygems, pypi, etc.)
-s, --severity=LEVEL    Minimum severity (critical, high, medium, low)
-f, --format=FORMAT     Output format (text, json)
-b, --branch=NAME       Branch context for database queries
    --stateless         Parse manifests directly without database
    --no-pager          Do not pipe output into a pager
```

## Examples

Show only critical and high severity:

```
$ git pkgs vulns -s high
```

Scan only npm packages:

```
$ git pkgs vulns -e npm
```

JSON output for CI/CD pipelines:

```
$ git pkgs vulns -f json
```

Compare vulnerabilities between releases:

```
$ git pkgs vulns v1.0.0
$ git pkgs vulns v2.0.0
```

## Subcommands

### blame

Show who introduced each vulnerability. When a commit was authored by a bot (like dependabot) but has a `Co-authored-by` trailer, the human co-author is shown instead:

```
$ git pkgs vulns blame
CRITICAL  CVE-2024-1234  lodash 4.17.15      abc1234  2024-03-15  Alice   "Add utility helpers"
HIGH      GHSA-xxxx      express 4.18.0      def5678  2024-02-01  Bob     "Bump express"
```

Show all historical vulnerability introductions (including fixed ones):

```
$ git pkgs vulns blame --all-time
CRITICAL  CVE-2024-1234  lodash 4.17.15      abc1234  2024-03-15  Alice   "Add utility helpers"  [fixed]
HIGH      GHSA-xxxx      express 4.18.0      def5678  2024-02-01  [bot]   "Bump express"  [ongoing]
```

Options: `-e`, `-s`, `-b`, `-f`, `--all-time`

### praise

Show who fixed vulnerabilities (the opposite of blame):

```
$ git pkgs vulns praise
CRITICAL  CVE-2024-1234  lodash            ghi9012  2024-04-01  Bob  "Bump lodash"  (12d after disclosure)
HIGH      GHSA-yyyy      express           jkl3456  2024-03-10  Alice  "Update express"  (5d after disclosure)
```

Show author leaderboard:

```
$ git pkgs vulns praise --summary
Author                   Fixes  Avg Days  Critical  High  Medium  Low
-------------------------------------------------------------------------
dependabot[bot]          104    175.4d         6    33      53    12
Andrew Nesbitt            88      8.8d         9    25      45     9
dependabot-preview[bot]   27     24.0d         3    12      11     1
```

Options: `-e`, `-s`, `-b`, `-f`, `--summary`

### exposure

Calculate exposure windows and remediation metrics for CRA compliance:

```
$ git pkgs vulns exposure --summary
+----------------------------------+
| Total vulnerabilities |        5 |
| Fixed                 |        3 |
| Ongoing               |        2 |
| Median remediation    |   8 days |
| Mean remediation      |  14 days |
| Oldest unpatched      |  45 days |
| Critical (avg)        | 3.0 days |
| High (avg)            |  12 days |
+----------------------------------+
```

Full table output:

```
$ git pkgs vulns exposure
Package     CVE            Introduced   Fixed        Exposed  Post-Disclosure
lodash      CVE-2024-1234  2023-01-10   2024-04-01   447d     12d
express     GHSA-xxxx      2024-02-01   -            ongoing  45d (ongoing)

+----------------------------------+
| Total vulnerabilities |        2 |
...
```

Show all-time stats for all historical vulnerabilities:

```
$ git pkgs vulns exposure --all-time --summary
+----------------------------------+
| Total vulnerabilities |      238 |
| Fixed                 |      234 |
| Ongoing               |        4 |
| Median remediation    |   0 days |
| Mean remediation      | 2.5 days |
| Oldest unpatched      |  94 days |
| Critical (avg)        | 0.1 days |
| High (avg)            | 2.2 days |
+----------------------------------+
```

Options: `-e`, `-s`, `-b`, `-f`, `--summary`, `--all-time`

### diff

Compare vulnerability state between two commits:

```
$ git pkgs vulns diff main feature-branch
+CRITICAL  CVE-2024-1234  lodash 4.17.15      (introduced in feature-branch)
-HIGH      GHSA-yyyy      express 4.17.0      (fixed in feature-branch)

$ git pkgs vulns diff v1.0.0 v2.0.0
$ git pkgs vulns diff HEAD~10
```

Options: `-e`, `-s`, `-b`, `-f`

### log

Show commits that introduced or fixed vulnerabilities:

```
$ git pkgs vulns log
abc1234  2024-03-15  Alice  "Add utility helpers"     +CVE-2024-1234
bcd2345  2024-02-20  Bob    "Security: update async"  -CVE-2023-9999
def5678  2024-02-01  [bot]  "Bump express"            +GHSA-xxxx

$ git pkgs vulns log --introduced  # Only show introductions
$ git pkgs vulns log --fixed       # Only show fixes
$ git pkgs vulns log --since="2024-01-01"
$ git pkgs vulns log --author=dependabot
```

Options: `-e`, `-s`, `-b`, `-f`, `--since`, `--until`, `--author`, `--introduced`, `--fixed`

### history

Show vulnerability timeline for a specific package or CVE:

```
$ git pkgs vulns history lodash
History for lodash

2023-01-10  Added lodash 4.17.10 (vulnerable to CVE-2024-1234)  abc1234  Alice
2023-06-15  Modified lodash 4.17.15 (vulnerable to CVE-2024-1234)  def5678  [bot]
2024-03-20  CVE-2024-1234 published (critical severity)
2024-04-01  Modified lodash 4.17.21  ghi9012  Bob

$ git pkgs vulns history CVE-2024-1234
$ git pkgs vulns history --since="2023-01-01"
```

Options: `-e`, `-f`, `--since`, `--until`

### show

Show details about a specific CVE:

```
$ git pkgs vulns show CVE-2024-1234
CVE-2024-1234 (critical severity)
Prototype Pollution in lodash

Affected packages:
  npm/lodash: >=0 <4.17.21 (fixed in 4.17.21)

Published: 2024-03-20

References:
  https://nvd.nist.gov/vuln/detail/CVE-2024-1234
  https://github.com/lodash/lodash/issues/4744

Your exposure:
  lodash 4.17.15 in package-lock.json
    Added: abc1234 2024-03-15 Alice "Add utility helpers"
    Fixed: ghi9012 2024-04-01 Bob "Bump lodash for CVE-2024-1234"
```

Options: `-f`, `-b`

## Syncing Vulnerability Data

The vulns command automatically fetches vulnerability data from OSV for any packages that haven't been checked recently (within 24 hours). To manually sync or force a refresh:

```
$ git pkgs vulns sync           # Sync stale packages
$ git pkgs vulns sync --refresh # Force refresh all packages (updates severity data too)
```

The sync command is useful when you want to update cached vulnerability data without running a scan. Use `--refresh` to re-fetch full vulnerability details, which updates severity levels and other metadata that may have changed since the initial fetch.

## Supported Ecosystems

The vulns command supports ecosystems that have lockfiles:

| Ecosystem   | Lockfile Examples                |
|-------------|----------------------------------|
| npm         | package-lock.json, yarn.lock     |
| rubygems    | Gemfile.lock                     |
| pypi        | Pipfile.lock, poetry.lock        |
| cargo       | Cargo.lock                       |
| go          | go.sum                           |
| maven       | pom.xml (with versions)          |
| nuget       | packages.lock.json               |
| packagist   | composer.lock                    |
| hex         | mix.lock                         |
| pub         | pubspec.lock                     |

## Data Source

Vulnerability data comes from the [OSV database](https://osv.dev), which aggregates security advisories from:

- GitHub Security Advisories (GHSA)
- National Vulnerability Database (CVE)
- RustSec (Rust)
- PyPI Advisory Database
- Go Vulnerability Database
- And many more

## Stateless Mode

By default, the vulns command uses the git-pkgs database for faster queries. If the database doesn't exist, it falls back to stateless mode automatically.

Force stateless mode (useful in CI):

```
$ git pkgs vulns --stateless
```

Stateless mode parses manifest files directly from git, which works without running `git pkgs init` first but provides no historical context.

## Caching

Vulnerability data is cached in the pkgs.sqlite3 database to avoid repeated API calls. Each package tracks when its vulnerabilities were last fetched. Packages are automatically refreshed if their data is more than 24 hours old.

The cache stores:
- **vulnerabilities**: Core CVE/GHSA data (severity, summary, published date)
- **vulnerability_packages**: Which packages are affected by each vulnerability
- **packages**: Metadata including when vulnerabilities were last synced

## Exit Codes

- 0: Scan completed (regardless of whether vulnerabilities were found)

Use `--format=json` and parse the output for CI checks that need to fail on vulnerabilities.

## How It Works

1. Get dependencies at the specified commit (from database snapshots or by parsing manifests)
2. Filter to ecosystems with OSV support
3. Check which packages need vulnerability data refreshed (never synced or >24h old)
4. Query OSV API in batch for packages needing refresh
5. Store vulnerability data in the local cache
6. Match vulnerability version ranges against our versions using the `vers` gem
7. Exclude withdrawn vulnerabilities
8. Display results sorted by severity
