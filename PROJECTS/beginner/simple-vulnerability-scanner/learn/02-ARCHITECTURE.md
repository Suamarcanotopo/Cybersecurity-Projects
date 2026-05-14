# System Architecture

This document breaks down how angela is designed and why certain architectural decisions were made. We'll trace requests through the system and explain the tradeoffs.

## High Level Architecture

```
┌──────────────┐
│     CLI      │  cobra commands (update, scan, check)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   Parser     │  Extract dependencies from pyproject.toml
│              │  or requirements.txt
└──────┬───────┘
       │
       ├─────────────────┬─────────────────┐
       ▼                 ▼                 ▼
┌──────────┐      ┌──────────┐      ┌──────────┐
│   PyPI   │      │ OSV.dev  │      │  Config  │
│  Client  │      │  Client  │      │  Loader  │
└────┬─────┘      └────┬─────┘      └────┬─────┘
     │                 │                  │
     ▼                 ▼                  ▼
┌──────────┐      ┌──────────┐      ┌──────────┐
│  Cache   │      │ Vuln DB  │      │ Settings │
└──────────┘      └──────────┘      └──────────┘
       │
       ▼
┌──────────────┐
│   Writer     │  Update dependency file preserving formatting
└──────────────┘
```

### Component Breakdown

**CLI Layer** (`internal/cli/`)
- Purpose: Parse command line arguments and orchestrate the workflow
- Responsibilities: Route `update`, `scan`, `check`, `cache`, and `init` commands to the appropriate handlers
- Interfaces: `cobra.Command` for argument parsing, returns error or nil

**Parser** (`internal/pyproject/` and `internal/requirements/`)
- Purpose: Extract dependency declarations from project files
- Responsibilities: Parse TOML or plain text, build `[]types.Dependency` with name, version spec, extras, and markers
- Interfaces: `ParseFile(path string) ([]types.Dependency, error)`

**PyPI Client** (`internal/pypi/`)
- Purpose: Query PyPI's Simple API for available package versions
- Responsibilities: HTTP requests with retry logic, ETag-based caching, PEP 440 version parsing
- Interfaces: `FetchVersions(ctx, name) ([]string, error)` for single package, `FetchAllVersions(ctx, names) []FetchResult` for concurrent batch

**OSV Client** (`internal/osv/`)
- Purpose: Query OSV.dev for known vulnerabilities
- Responsibilities: Batch vulnerability queries, individual CVE detail fetches, severity extraction, deduplication
- Interfaces: `ScanPackages(ctx, []PackageQuery) (map[string][]Vulnerability, error)`

**Cache** (`internal/pypi/cache.go`)
- Purpose: File-based cache for PyPI responses to avoid hammering the API
- Responsibilities: Serialize JSON to `~/.angela/cache/`, check TTL freshness, handle ETags
- Interfaces: `Get(key) (*CacheEntry, bool)`, `Set(key, entry) error`

**Config Loader** (`internal/config/`)
- Purpose: Read user preferences from `.angela.toml` or `[tool.angela]` in pyproject.toml
- Responsibilities: Parse TOML config, extract min-severity, ignore lists, vuln suppression
- Interfaces: `Load(pyprojectPath) Config`

**Writer** (`internal/pyproject/writer.go` and `internal/requirements/writer.go`)
- Purpose: Surgical file edits to update version specifiers without destroying formatting
- Responsibilities: Regex-based find/replace on raw bytes, TOML validation after edits, atomic writes
- Interfaces: `UpdateFile(path, updates map[string]string) error`

## Data Flow

### Primary Use Case: Update Dependencies

Step by step walkthrough of what happens when you run `angela update --file pyproject.toml`:

```
1. CLI parses arguments → update.go:runUpdate() (internal/cli/update.go:200-291)
   Extracts file path, loads angela config (ignore lists, min-severity)

2. runUpdate() → pyproject.ParseFile() (internal/pyproject/parser.go:18-50)
   Unmarshals TOML, extracts [project.dependencies] and [project.optional-dependencies]
   Returns []types.Dependency with name, spec, extras, markers, group

3. runUpdate() → pypi.FetchAllVersions() (internal/pypi/client.go:135-167)
   Spawns up to 10 concurrent goroutines (one per package)
   Each calls FetchVersions() which:
   - Checks cache for unexpired entry with matching ETag
   - If cache hit: return cached versions
   - If cache miss: HTTP GET to https://pypi.org/simple/{package}/
   - Parse JSON response, extract "versions" array
   - Store in cache with ETag from response headers

4. runUpdate() → resolveUpdates() (internal/cli/update.go:293-350)
   For each dependency:
   - Parse current version using pypi.ParseVersion() (internal/pypi/version.go:60-112)
   - Find latest stable with pypi.LatestStable() (filters pre-releases)
   - Compare versions using Version.Compare() (PEP 440 ordering)
   - If newer: classify change (major/minor/patch) and build UpdateResult
   - If --safe flag: skip major bumps
   - If in config.Ignore: skip with reason

5. runUpdate() → scanForVulns() (internal/cli/update.go:352-372) [if --vulns flag]
   Build []osv.PackageQuery from dependencies (name + extracted version)
   Call osv.ScanPackages() which:
   - POST to https://api.osv.dev/v1/querybatch with all packages
   - Extract unique vulnerability IDs from response
   - Fetch full details for each vuln with concurrent requests (max 15 workers)
   - Deduplicate CVE/GHSA/PYSEC aliases
   - Extract severity, summary, fixed version, link
   Returns map[packageName][]Vulnerability

6. runUpdate() → pyproject.UpdateFile() (internal/pyproject/writer.go:99-118)
   For each package with updates:
   - Build regex matching package name with normalized form (PEP 503)
   - Find dependency line in raw file bytes
   - Replace only version specifier, keep quotes, extras, markers
   - Validate result is still valid TOML
   - Atomic write: tmp file + rename

7. runUpdate() → Print results (internal/cli/output.go:35-93)
   Display updates in terminal with color coding (red=major, yellow=minor, green=patch)
   Show vulnerabilities by severity (critical → high → moderate → low)
   Print summary with total packages, updates applied, vulnerabilities found
```

### Secondary Use Case: Check Without Updating

The `check` command follows steps 1-5 above but skips step 6 (file writing). It's a dry run mode.

### Vulnerability Scan Only

The `scan` command skips version checking entirely:

```
1. CLI → scan command (internal/cli/update.go:403-440)
2. Parse dependencies from file
3. scanForVulns() against current installed versions
4. Print vulnerability report
```

This is faster than `update --vulns` because it doesn't query PyPI for version data.

## Design Patterns

### Pattern 1: Bounded Concurrency with errgroup

**What it is:**
Go's `errgroup` package provides coordinated goroutine execution with error propagation and context cancellation. `SetLimit()` caps how many goroutines run simultaneously.

**Where we use it:**
`internal/pypi/client.go:135-167` for parallel PyPI requests:

```go
g, ctx := errgroup.WithContext(ctx)
g.SetLimit(c.maxWorkers)  // 10 concurrent requests max

for _, name := range names {
    g.Go(func() (err error) {
        defer func() {
            if r := recover(); r != nil {
                err = fmt.Errorf("panic fetching %s: %v", name, r)
            }
        }()
        
        versions, fetchErr := c.FetchVersions(ctx, name)
        mu.Lock()
        results = append(results, FetchResult{...})
        mu.Unlock()
        return nil  // Don't propagate individual failures
    })
}

_ = g.Wait()
```

**Why we chose it:**
PyPI rate-limits aggressive clients. 10 concurrent requests balances speed (vs sequential) with politeness (vs 50 concurrent). Alternative approaches:
- Worker pool with channels: More boilerplate, same functionality
- Unlimited goroutines: Hammers PyPI, might get IP banned
- Sequential requests: Takes 30+ seconds for typical projects

**Trade-offs:**
- Pros: Simple code, respects rate limits, automatic context cancellation
- Cons: Fixed concurrency limit (not adaptive), no request prioritization

### Pattern 2: Regex-Based File Surgery

**What it is:**
Instead of parsing TOML → modifying struct → re-serializing, angela uses compiled regex patterns to locate and replace only the version specifier in the raw file bytes.

**Where we use it:**
`internal/pyproject/writer.go:54-84` and `internal/requirements/writer.go:17-47`

```go
func buildDepPattern(name string, quote byte) *regexp.Regexp {
    normalized := pypi.NormalizeName(name)
    parts := strings.Split(normalized, "-")
    for i, p := range parts {
        parts[i] = regexp.QuoteMeta(p)
    }
    namePattern := strings.Join(parts, `[-_.]?`)
    
    q := string(quote)
    notQ := `[^` + q + `]`
    
    return regexp.MustCompile(
        `(?i)` +
        q +
        `(` + namePattern + `)` +           // Group 1: package name
        `(\[[^\]]*\])?` +                   // Group 2: extras
        `(\s*[><=!~]` + notQ + `*?)` +     // Group 3: version spec
        `(;` + notQ + `*)?` +              // Group 4: markers
        q,
    )
}
```

**Why we chose it:**
Go's TOML libraries (BurntSushi/toml, pelletier/go-toml) don't preserve comments or formatting during unmarshal/marshal. Comments, blank lines, and quote styles all get destroyed. Regex surgery keeps everything intact except the version number.

**Trade-offs:**
- Pros: Preserves all formatting, works on any valid TOML
- Cons: More complex than struct manipulation, requires validation after edit, can't handle malformed files gracefully

### Pattern 3: File-Based Cache with ETag Support

**What it is:**
HTTP ETags are opaque identifiers servers send to indicate resource version. Clients include `If-None-Match: {etag}` on subsequent requests. If unchanged, server returns 304 Not Modified instead of the full response.

**Where we use it:**
`internal/pypi/cache.go:23-88`

```go
type CacheEntry struct {
    ETag     string    `json:"etag"`
    Versions []string  `json:"versions"`
    CachedAt time.Time `json:"cached_at"`
}

// Check cache before making request
entry, hit := c.cache.Get(normalized)
if hit && c.cache.IsFresh(entry) {
    return entry.Versions, nil
}

// Add ETag to request if we have one
if entry != nil && entry.ETag != "" {
    req.Header.Set("If-None-Match", entry.ETag)
}

// Handle 304 response
if resp.StatusCode == http.StatusNotModified {
    c.cache.Touch(normalized)  // Refresh TTL
    return entry.Versions, nil
}
```

**Why we chose it:**
PyPI responses rarely change (package versions are immutable once published). ETags let us skip downloading the same JSON repeatedly. Combined with 1-hour TTL, typical usage has >90% cache hit rate.

**Trade-offs:**
- Pros: Reduces PyPI load, faster repeated scans, respects HTTP caching semantics
- Cons: Stale data possible within TTL window, cache directory can grow large

## Layer Separation

angela uses a simple three-layer architecture:

```
┌────────────────────────────────────┐
│    Layer 1: CLI / Presentation     │
│    - Cobra command handlers        │
│    - Terminal output formatting    │
│    - Color and spinner UI          │
└────────────────────────────────────┘
           ↓
┌────────────────────────────────────┐
│    Layer 2: Business Logic         │
│    - Version resolution            │
│    - Vulnerability scanning        │
│    - Update decision logic         │
└────────────────────────────────────┘
           ↓
┌────────────────────────────────────┐
│    Layer 3: Data Access            │
│    - PyPI HTTP client              │
│    - OSV.dev HTTP client           │
│    - File I/O (cache, configs)     │
└────────────────────────────────────┘
```

### Why Layers?

Separation of concerns. The CLI layer doesn't know PyPI's API format. The PyPI client doesn't know about terminal colors. If PyPI changes their JSON schema, only Layer 3 changes. If we want a JSON output mode instead of pretty terminal UI, only Layer 1 changes.

### What Lives Where

**Layer 1 (CLI):**
- Files: `internal/cli/update.go`, `internal/cli/output.go`, `internal/ui/`
- Imports: Can import from Layer 2 and Layer 3
- Forbidden: Must not contain HTTP logic, version parsing, or file I/O

**Layer 2 (Business Logic):**
- Files: `internal/pypi/version.go`, `internal/config/config.go`
- Imports: Can import Layer 3, not Layer 1
- Forbidden: Must not do terminal output or know about CLI flags

**Layer 3 (Data Access):**
- Files: `internal/pypi/client.go`, `internal/osv/client.go`, `internal/pypi/cache.go`
- Imports: Only pkg/types and standard library
- Forbidden: Must not import anything from internal/cli or internal/ui

## Data Models

### Dependency

```go
// pkg/types/types.go:8-15
type Dependency struct {
    Name    string     // Package name (e.g., "requests")
    Spec    string     // Version specifier (e.g., ">=2.28.0")
    Extras  []string   // Optional extras (e.g., ["async", "security"])
    Markers string     // Environment markers (e.g., "python_version>='3.8'")
    Group   string     // Dependency group (e.g., "dev", "test")
}
```

**Fields explained:**
- `Name`: PEP 503 normalized package name. angela uses `pypi.NormalizeName()` which converts to lowercase and treats `-`, `_`, `.` as equivalent.
- `Spec`: PEP 440 version specifier. Can be `>=2.0`, `==1.5.0`, `>=3.0,<4.0`, etc.
- `Extras`: Optional feature sets like `requests[security]`. PyPI packages can define extras that pull in additional dependencies.
- `Markers`: Python environment conditions like `platform_system=="Windows"`. Pip only installs the dependency if markers evaluate true.
- `Group`: For pyproject.toml's optional-dependencies, tracks which group it came from.

**Relationships:**
Parsed from file → checked against PyPI → scanned for vulns → potentially updated

### Vulnerability

```go
// pkg/types/types.go:26-34
type Vulnerability struct {
    ID       string     // Primary ID (e.g., "CVE-2023-32681")
    Aliases  []string   // Alternative IDs (e.g., ["GHSA-j8r2...", "PYSEC-2023-80"])
    Summary  string     // Human-readable description
    Severity string     // CRITICAL, HIGH, MODERATE, LOW, UNKNOWN
    FixedIn  string     // First version that patches the vuln (e.g., "2.31.0")
    Link     string     // URL to advisory (GitHub, NVD, vendor page)
}
```

**Fields explained:**
- `ID`: OSV.dev's primary identifier. Could be CVE, GHSA, or PYSEC depending on source.
- `Aliases`: Same vulnerability under different IDs. angela uses this for deduplication.
- `Summary`: First sentence of the advisory. Truncated to fit terminal width.
- `Severity`: Extracted from CVSS score or database_specific.severity. Falls back to "UNKNOWN" if missing.
- `FixedIn`: Parsed from OSV's `affected[].ranges[].events[].fixed` field. Empty if no patch available.
- `Link`: Preference order: ADVISORY type > WEB type > first reference. Gives users somewhere to read more.

**Relationships:**
Returned by OSV query → filtered by severity/ignore list → displayed with color coding

## Security Architecture

### Threat Model

What we're protecting against:

1. **Installing vulnerable dependencies** - User has old package versions with known CVEs. angela shows them which packages have fixes available and what the CVEs are.

2. **Accidentally upgrading to pre-releases** - User wants stable packages, but naive "latest version" logic might pick `3.0a1` over `2.5.0`. angela filters pre-releases by default.

3. **Breaking changes from major bumps** - User has working code on `django==3.2`. Upgrading to `4.0` might break APIs. angela's `--safe` flag skips major version bumps.

What we're NOT protecting against (out of scope):

- **Malicious code in dependencies** - angela doesn't do static analysis or sandboxing. It trusts PyPI's package integrity.
- **Transitive dependency vulnerabilities** - angela only scans packages explicitly in your dependency file. If `requests` depends on a vulnerable `urllib3`, angela won't catch it unless you also list `urllib3`.
- **Supply chain attacks via package takeover** - If someone hijacks a legitimate package and pushes a backdoored version with no CVE yet, angela won't detect it.

### Defense Layers

angela implements defense in depth:

```
Layer 1: Configuration validation
    ↓ (Reject invalid TOML, malformed version specs)
Layer 2: Safe defaults
    ↓ (Filter pre-releases, limit concurrent requests)
Layer 3: Vulnerability scanning
    ↓ (Query OSV.dev for known CVEs)
```

**Why multiple layers?**

If the config loader has a bug and doesn't validate min-severity properly, the default "low" threshold still provides some protection. If PyPI returns garbage JSON, the version parser will reject it rather than corrupting state. Each layer catches a different failure mode.

## Storage Strategy

### File-Based Cache

**What we store:**
- PyPI version lists (package name → `["1.0", "1.1", "2.0"]`)
- HTTP ETags for conditional requests
- Timestamps for TTL expiration

**Why this storage:**
Simple, no dependencies, works on all platforms. Alternative would be something like SQLite, but that adds complexity and a C dependency (for cgo). File-based cache is fast enough (50-100μs read latency) and requires zero configuration.

**Schema design:**
```
~/.angela/cache/
├── requests.json
├── django.json
└── flask.json
```

Each file contains:
```json
{
  "etag": "\"686897696a7c876b7e\"",
  "versions": ["2.0.0", "2.28.0", "2.31.0"],
  "cached_at": "2024-01-15T10:30:00Z"
}
```

The cache key is the normalized package name. `filepath.Base()` prevents directory traversal (see `internal/pypi/cache.go:85-88`):

```go
func (c *Cache) path(key string) string {
    safe := filepath.Base(key)  // Strips path separators
    return filepath.Join(c.dir, safe+".json")
}
```

Even if someone tries to cache `../../../etc/passwd`, it becomes `passwd.json` in the cache directory.

## Performance Considerations

### Bottlenecks

Where this system gets slow under load:

1. **PyPI Simple API requests** - Network round-trip time dominates for uncached queries. Typical latency is 50-200ms per request. With 50 dependencies, sequential would take 2.5-10 seconds. Concurrent + caching brings it down to 500ms.

2. **OSV.dev batch queries** - The batch endpoint handles up to 1000 packages per request, but the response can be 100KB+ for heavily-affected packages. Fetching individual vulnerability details adds another round-trip per unique CVE.

3. **TOML parsing** - pelletier/go-toml v2 is fast (sub-millisecond for typical pyproject.toml), but regex validation after updates adds cost. Each regex compilation takes ~10μs, and we do it twice (double quotes, then single quotes).

### Optimizations

What we did to make it faster:

- **HTTP connection reuse**: `internal/pypi/client.go:53-58` configures `MaxIdleConnsPerHost` to match concurrency limit. Connections stay open between requests, saving TCP handshake time.

- **Bounded goroutines**: `errgroup.SetLimit(10)` prevents spawning 50+ goroutines and exhausting file descriptors. Each goroutine has overhead (2KB+ stack), so limiting them helps.

- **Cache with 1-hour TTL**: `internal/pypi/cache.go:11` sets `DefaultCacheTTL = 1 * time.Hour`. Running angela twice within an hour has near-zero latency (cache hit).

- **Compiled regex patterns**: angela compiles regex patterns once in `buildDepPattern()` rather than on every match. Go's `regexp.MustCompile()` at startup would be even better, but we need dynamic patterns (package name varies).

### Scalability

**Vertical scaling:**
angela is CPU-bound during regex matching and memory-bound during concurrent HTTP requests. Adding more CPU cores doesn't help much (already using 10 goroutines). Adding RAM helps if you're scanning 1000+ dependencies (cache grows large).

**Horizontal scaling:**
Not applicable. angela is a CLI tool that runs on one machine. If you wanted to scan 10,000 projects, you'd run 10,000 angela processes in parallel (e.g., in Kubernetes jobs).

What needs to change to support higher scale: Shared cache layer (Redis/Memcached) instead of per-process files. Connection pooling with server-side support. Rate limit coordination across processes.

## Design Decisions

### Decision 1: Go Instead of Python

**What we chose:**
Write the dependency scanner in Go, not Python.

**Alternatives considered:**
- Python with `packaging` library: Native ecosystem, easier to use Python's own version parser
- Rust: Better performance, harder to learn
- Shell script with curl/jq: Simplest possible, but terrible error handling

**Trade-offs:**
What we gained:
- Static binary (no Python installation required)
- Fast startup time (no import overhead)
- Excellent concurrency primitives (goroutines, errgroup)

What we gave up:
- Had to implement PEP 440 from scratch
- Can't use pip's resolver logic directly
- Smaller ecosystem for TOML libraries

**Reasoning**: angela needs to be fast (scan 50 packages in <1 second) and portable (run on any machine). Go compiles to a single binary with no runtime dependencies. Python would work but would be slower and require the right Python version installed.

### Decision 2: File-Based Cache vs In-Memory

**What we chose:**
File-based cache at `~/.angela/cache/` with 1-hour TTL.

**Alternatives considered:**
- In-memory only: Fastest, but lost on exit
- SQLite: More features (queries, indexes), but heavier dependency
- No cache: Simplest code, but slow repeated runs

**Trade-offs:**
What we gained:
- Persistent across runs (developer scans same project multiple times)
- Simple implementation (just JSON serialization)
- No daemon required (unlike Redis)

What we gave up:
- Cache directory grows unbounded (no automatic cleanup)
- No LRU eviction (files stay until TTL expires)
- Slower than in-memory (disk I/O vs RAM)

**Reasoning**: angela's typical use case is "run it every hour in CI" or "run it when updating dependencies manually". File-based cache covers both. The cache size is small (50 packages × 5KB each = 250KB), so disk space isn't a concern.

## Deployment Architecture

angela runs as a local CLI tool, not a server. There's no deployment topology. Users install the binary via:

```bash
go install github.com/CarterPerez-dev/angela/cmd/angela@latest
```

Or download from GitHub releases. The binary has no external dependencies (Go's runtime is statically linked).

## Error Handling Strategy

### Error Types

1. **Network errors** - PyPI or OSV.dev unreachable, timeout, DNS failure. Handled with retries and exponential backoff in `internal/pypi/client.go:169-200`.

2. **Parse errors** - Invalid TOML syntax, malformed version strings, unparseable JSON responses. Bubbled up with `fmt.Errorf("parse %s: %w", path, err)` for context.

3. **File system errors** - Permission denied, disk full, path not found. Checked at entry points (`os.ReadFile`, `os.WriteFile`) and wrapped with path context.

### Recovery Mechanisms

**Network failure scenario:**
- Detection: `c.http.Do(req)` returns error or status code ≥500
- Response: Retry with exponential backoff (500ms, 1s, 2s)
- Recovery: On third retry success, log warning but continue. On all retries failed, return error and use cached data if available.

Example from `internal/pypi/client.go:169-200`:

```go
for attempt := range maxRetries {
    if attempt > 0 {
        delay := time.Duration(1<<shift) * baseRetryMs * time.Millisecond
        select {
        case <-ctx.Done():
            return nil, ctx.Err()
        case <-time.After(delay):
        }
    }

    resp, err := c.http.Do(req)
    if err != nil {
        lastErr = err
        continue  // Retry
    }

    if resp.StatusCode >= 500 {
        _ = resp.Body.Close()
        lastErr = fmt.Errorf("server error: %d", resp.StatusCode)
        continue  // Retry server errors
    }

    return resp, nil  // Success
}

return nil, fmt.Errorf("after %d attempts: %w", maxRetries, lastErr)
```

## Extensibility

### Where to Add Features

Want to add SBOM (Software Bill of Materials) generation? Here's where it goes:

1. Add new command in `internal/cli/update.go:` following the pattern of `newScanCmd()`
2. Create `internal/sbom/generator.go` to build the SBOM JSON structure
3. Use existing `internal/pyproject/parser.go` to get dependency list
4. Format output in `internal/cli/output.go` (or write directly to file)

The key is: parsers and clients are reusable. CLI commands orchestrate them.

### Plugin Architecture

angela doesn't have plugins yet. If it did, the interface would look like:

```go
type VulnerabilitySource interface {
    QueryVulnerabilities(ctx context.Context, packages []Package) ([]Vulnerability, error)
}
```

Then angela could support OSV.dev, Snyk, GitHub Advisory, and custom internal databases via the same interface. This is left as an exercise for readers (see 04-CHALLENGES.md).

## Limitations

Current architectural limitations:

1. **No transitive dependency scanning** - angela only checks packages explicitly in your dependency file. If `requests` depends on a vulnerable `urllib3`, you won't know unless you also list `urllib3`. Fixing this requires a full dependency resolver (like pip's), which is complex.

2. **No offline mode** - angela requires network access to PyPI and OSV.dev. Adding offline support would need bundled vulnerability database snapshots and local PyPI mirrors.

3. **Single project at a time** - You can't point angela at 10 projects and get aggregated results. The CLI is designed for one `pyproject.toml` per invocation.

These are not bugs, they're conscious trade-offs to keep the beginner project scope manageable. [04-CHALLENGES.md](./04-CHALLENGES.md) explains how to address each.

## Comparison to Similar Systems

### vs pip-audit

How we're different:
- pip-audit requires a Python installation and uses pip's resolver. angela is a standalone Go binary.
- pip-audit scans installed packages (`pip list` output). angela scans dependency files before installation.
- pip-audit doesn't update versions. angela does both scanning and updating.

Why we made different choices: angela is designed for CI/CD where you want to check *before* installing. pip-audit is better for auditing production environments.

### vs Dependabot

How we're different:
- Dependabot is a GitHub bot that opens PRs. angela is a local CLI tool.
- Dependabot knows about all ecosystems (npm, PyPI, Maven, etc.). angela only does PyPI.
- Dependabot has sophisticated version resolution with security vs compatibility tradeoffs. angela has simple "latest stable" logic.

Why we made different choices: Dependabot is a production service with a team maintaining it. angela is a learning project. The architecture reflects that (simple and hackable vs robust and comprehensive).

## Key Files Reference

Quick map of where to find things:

- `cmd/angela/main.go` - Entry point, just calls cli.Execute()
- `internal/cli/update.go` - All command implementations (update, scan, check)
- `internal/pypi/client.go` - HTTP client with retries and caching
- `internal/pypi/version.go` - PEP 440 parser and comparison logic
- `internal/osv/client.go` - Vulnerability scanner with batch queries
- `internal/pyproject/writer.go` - Regex-based TOML editing
- `internal/ui/spinner.go` - Terminal spinner animation
- `pkg/types/types.go` - Shared structs (Dependency, Vulnerability, etc.)

## Next Steps

Now that you understand the architecture:
1. Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for line-by-line code walkthrough
2. Try modifying the cache TTL in `internal/pypi/cache.go:11` and see how it affects performance
3. Add a new command (like `angela stats` to show cache hit rate) following the CLI patterns
