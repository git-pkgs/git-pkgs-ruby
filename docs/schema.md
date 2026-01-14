# Database Schema

git-pkgs stores dependency history in a SQLite database at `.git/pkgs.sqlite3`. See [internals.md](internals.md) for how the schema is used.

## Tables

### branches

Tracks which branches have been analyzed.

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| name | string | Branch name (e.g., "main", "develop") |
| last_analyzed_sha | string | SHA of last commit analyzed for incremental updates |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `name` (unique)

### commits

Stores commit metadata for commits that have been analyzed.

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| sha | string | Full commit SHA |
| message | text | Commit message |
| author_name | string | Author name |
| author_email | string | Author email |
| committed_at | datetime | Commit timestamp |
| has_dependency_changes | boolean | True if this commit modified dependencies |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `sha` (unique)

### branch_commits

Join table linking commits to branches. A commit can belong to multiple branches.

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| branch_id | integer | Foreign key to branches |
| commit_id | integer | Foreign key to commits |
| position | integer | Order of commit in branch history |

Indexes: `(branch_id, commit_id)` (unique)

### manifests

Stores manifest file metadata.

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| path | string | File path (e.g., "Gemfile", "package.json") |
| platform | string | Package manager (e.g., "rubygems", "npm") |
| kind | string | Manifest type (e.g., "manifest", "lockfile") |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `path`

### dependency_changes

Records each dependency addition, modification, or removal.

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| commit_id | integer | Foreign key to commits |
| manifest_id | integer | Foreign key to manifests |
| name | string | Package name |
| platform | string | Package manager |
| change_type | string | "added", "modified", or "removed" |
| requirement | string | Version constraint after change |
| previous_requirement | string | Version constraint before change (for modifications) |
| dependency_type | string | "runtime", "development", etc. |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `name`, `platform`, `(commit_id, name)`

### dependency_snapshots

Stores the complete dependency state at each commit that has changes. Enables O(1) queries for "what dependencies existed at commit X" without replaying history.

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| commit_id | integer | Foreign key to commits |
| manifest_id | integer | Foreign key to manifests |
| name | string | Package name |
| platform | string | Package manager |
| requirement | string | Version constraint |
| dependency_type | string | "runtime", "development", etc. |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `(commit_id, manifest_id, name)` (unique), `name`, `platform`

### packages

Tracks packages for vulnerability sync status.

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| purl | string | Package URL (e.g., "pkg:gem/rails") |
| ecosystem | string | Package manager (e.g., "rubygems") |
| name | string | Package name |
| latest_version | string | Latest known version (optional) |
| license | string | License identifier (optional) |
| description | text | Package description (optional) |
| homepage | string | Homepage URL (optional) |
| repository_url | string | Source repository URL (optional) |
| source | string | Data source (optional) |
| enriched_at | datetime | When package metadata was enriched |
| vulns_synced_at | datetime | When vulnerabilities were last synced from OSV |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `purl` (unique)

### versions

Stores per-version metadata for packages.

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| purl | string | Full versioned purl (e.g., "pkg:npm/lodash@4.17.21") |
| package_purl | string | Parent package purl (e.g., "pkg:npm/lodash") |
| license | string | License for this specific version |
| published_at | datetime | When this version was published |
| integrity | text | Integrity hash (e.g., SHA256) |
| source | string | Data source |
| enriched_at | datetime | When metadata was fetched |
| created_at | datetime | |
| updated_at | datetime | |

Indexes: `purl` (unique), `package_purl`

### vulnerabilities

Caches vulnerability data from OSV.

| Column | Type | Description |
|--------|------|-------------|
| id | string | Primary key (CVE-2024-1234, GHSA-xxxx, etc.) |
| aliases | text | Comma-separated alternative IDs for the same vulnerability |
| severity | string | critical, high, medium, or low |
| cvss_score | float | CVSS numeric score (0.0-10.0) |
| cvss_vector | string | Full CVSS vector string |
| references | text | JSON array of {type, url} objects |
| summary | text | Short description |
| details | text | Full vulnerability details |
| published_at | datetime | When the vulnerability was disclosed |
| withdrawn_at | datetime | When the vulnerability was retracted (if ever) |
| modified_at | datetime | When the OSV record was last modified |
| fetched_at | datetime | When we last fetched from OSV |

### vulnerability_packages

Maps which packages are affected by each vulnerability.

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| vulnerability_id | string | Foreign key to vulnerabilities |
| ecosystem | string | OSV ecosystem name (e.g., "RubyGems") |
| package_name | string | Package name |
| affected_versions | text | Version range expression (e.g., "<4.17.21") |
| fixed_versions | text | Comma-separated list of fixed versions |

Indexes: `(ecosystem, package_name)`, `vulnerability_id`, `(vulnerability_id, ecosystem, package_name)` (unique)

## Relationships

```
branches ──┬── branch_commits ──┬── commits
           │                    │
           │                    ├── dependency_changes ──── manifests
           │                    │
           │                    └── dependency_snapshots ── manifests
           │
           └── last_analyzed_sha (references commits.sha)

packages ──── versions (via package_purl)

vulnerabilities ──── vulnerability_packages
```
