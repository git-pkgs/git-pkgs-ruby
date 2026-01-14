# Package Enrichment

git-pkgs can fetch additional metadata about your dependencies from the [ecosyste.ms Packages API](https://packages.ecosyste.ms/). This powers the `outdated` and `licenses` commands.

## outdated

Show packages that have newer versions available in their registries.

```
$ git pkgs outdated
lodash      4.17.15  ->  4.17.21  (patch)
express     4.17.0   ->  4.19.2   (minor)
webpack     4.46.0   ->  5.90.3   (major)

3 outdated packages: 1 major, 1 minor, 1 patch
```

Major updates are shown in red, minor in yellow, patch in cyan.

### Options

```
-e, --ecosystem=NAME    Filter by ecosystem
-r, --ref=REF           Git ref to check (default: HEAD)
-f, --format=FORMAT     Output format (text, json)
    --major             Show only major version updates
    --minor             Show only minor or major updates (skip patch)
    --stateless         Parse manifests directly without database
```

### Examples

Show only major updates:

```
$ git pkgs outdated --major
webpack     4.46.0   ->  5.90.3   (major)
```

Check a specific release:

```
$ git pkgs outdated v1.0.0
```

JSON output:

```
$ git pkgs outdated -f json
```

## licenses

Show licenses for dependencies with optional compliance checks.

```
$ git pkgs licenses
lodash      MIT       (npm)
express     MIT       (npm)
request     Apache-2.0  (npm)
```

### Options

```
-e, --ecosystem=NAME    Filter by ecosystem
-r, --ref=REF           Git ref to check (default: HEAD)
-f, --format=FORMAT     Output format (text, json, csv)
    --allow=LICENSES    Comma-separated list of allowed licenses
    --deny=LICENSES     Comma-separated list of denied licenses
    --permissive        Only allow permissive licenses (MIT, Apache, BSD, etc.)
    --copyleft          Flag copyleft licenses (GPL, AGPL, etc.)
    --unknown           Flag packages with unknown/missing licenses
    --group             Group output by license
    --stateless         Parse manifests directly without database
```

### Compliance Checks

Only allow permissive licenses:

```
$ git pkgs licenses --permissive
lodash      MIT       (npm)
express     MIT       (npm)
gpl-pkg     GPL-3.0   (npm)  [copyleft]

1 license violation found
```

Explicit allow list:

```
$ git pkgs licenses --allow=MIT,Apache-2.0
```

Deny specific licenses:

```
$ git pkgs licenses --deny=GPL-3.0,AGPL-3.0
```

Flag packages with no license information:

```
$ git pkgs licenses --unknown
```

### Output Formats

Group by license:

```
$ git pkgs licenses --group
MIT (45)
  lodash
  express
  ...

Apache-2.0 (12)
  request
  ...
```

CSV for spreadsheets:

```
$ git pkgs licenses -f csv > licenses.csv
```

JSON for scripting:

```
$ git pkgs licenses -f json
```

### Exit Codes

The licenses command exits with code 1 if any violations are found. This makes it suitable for CI pipelines:

```yaml
- run: git pkgs licenses --stateless --permissive
```

### License Categories

Permissive licenses (allowed with `--permissive`):
MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC, Unlicense, CC0-1.0, 0BSD, WTFPL, Zlib, BSL-1.0

Copyleft licenses (flagged with `--copyleft` or `--permissive`):
GPL-2.0, GPL-3.0, LGPL-2.1, LGPL-3.0, AGPL-3.0, MPL-2.0 (and their variant identifiers)

## Data Source

Both commands fetch package metadata from [ecosyste.ms](https://packages.ecosyste.ms/), which aggregates data from npm, RubyGems, PyPI, Cargo, and other package registries.

## Caching

Package metadata is cached in the pkgs.sqlite3 database. Each package tracks when it was last enriched, and stale data (older than 24 hours) is automatically refreshed on the next query.

The cache stores:
- Latest version number
- License (SPDX identifier)
- Description
- Homepage URL
- Repository URL

## Stateless Mode

Both commands support `--stateless` mode, which parses manifest files directly from git without requiring a database. This is useful in CI environments where you don't want to run `git pkgs init` first.

```
$ git pkgs outdated --stateless
$ git pkgs licenses --stateless --permissive
```

In stateless mode, package metadata is fetched fresh each time and cached only in memory for the duration of the command.
