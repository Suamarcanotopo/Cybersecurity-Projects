# Implementation Guide

This document walks through the actual code. We'll build key features step by step and explain the decisions along the way.

## File Structure Walkthrough

```
simple-vulnerability-scanner/
├── cmd/angela/
│   └── main.go              # 7 lines: imports cli, calls Execute()
├── internal/
│   ├── cli/
│   │   ├── update.go        # 440 lines: cobra commands, orchestration
│   │   └── output.go        # 330 lines: terminal formatting, colors
│   ├── pypi/
│   │   ├── client.go        # 200 lines: HTTP client, concurrency
│   │   ├── cache.go         # 88 lines: file-based cache with ETag
│   │   └── version.go       # 280 lines: PEP 440 parser and comparison
│   ├── osv/
│   │   └── client.go        # 290 lines: vulnerability scanner
│   ├── pyproject/
│   │   ├── parser.go        # 90 lines: TOML dependency extraction
│   │   └── writer.go        # 118 lines: regex-based TOML editing
│   ├── requirements/
│   │   ├── parser.go        # 70 lines: requirements.txt parser
│   │   └── writer.go        # 80 lines: requirements.txt updater
│   ├── config/
│   │   └── config.go        # 70 lines: configuration loader
│   └── ui/
│       ├── banner.go        # ASCII art and branding
│       ├── color.go         # Color helper functions
│       ├── spinner.go       # Terminal spinner
│       └── symbol.go        # Unicode symbols
└── pkg/types/
    └── types.go             # 40 lines: shared data structures
```

## Building the PEP 440 Version Parser

### Step 1: Define the Version Structure

What we're building: A parser that handles every variant of Python version strings per PEP 440.

Create the `Version` type in `internal/pypi/version.go:41-51`:

```go
type Version struct {
    Raw     string
    Epoch   int
    Release []int    // [1, 2, 3] for "1.2.3"
    PreKind string   // "a", "b", or "rc"
    PreNum  int
    Post    int      // -1 means absent
    Dev     int      // -1 means absent
    Local   string
}
```

**Why this code works:**
- `Raw`: Stores original input for debugging. When comparing `"v1.0.0"` vs `"1.0.0"`, you want to know which form the user wrote.
- `Release []int`: Variable length slice handles `"1.0"`, `"1.0.0"`, `"1.0.0.0"`, etc. Python versions can have arbitrary depth.
- `Post int` and `Dev int` use `-1` as sentinel. This distinguishes "not present" from "present with value 0". Both `1.0.post0` and `1.0.post` are valid PEP 440 (implicit zero), but different from `1.0` (no post component).

**Common mistakes here:**
```go
// Wrong: can't distinguish "absent" from "zero"
type Version struct {
    Post int  // Is 0 "no post-release" or "post0"?
}

// Why this fails: Version("1.0").Post == 0 and Version("1.0.post0").Post == 0
// are identical, but PEP 440 treats them as equal anyway. The real issue is
// when sorting: math.MinInt sentinel in preKey() depends on -1 meaning "absent"
```

### Step 2: Build the Regex Pattern

Now we need to parse version strings into this structure.

In `internal/pypi/version.go:53-63`:

```go
var versionRe = regexp.MustCompile(
    `(?i)^v?` +
        `(?:(\d+)!)?` +                  // Epoch (optional)
        `(\d+(?:\.\d+)*)` +              // Release segments (required)
        `(?:[-_.]?(alpha|a|beta|b|...|rc)[-_.]?(\d*))?` +  // Pre-release
        `(?:[-_.]?(post|rev|r)[-_.]?(\d*)|-(\d+))?` +      // Post-release
        `(?:[-_.]?(dev)[-_.]?(\d*))?` +  // Dev release
        `(?:\+([a-z0-9]...))?$`,         // Local version
)
```

**What's happening:**
1. `(?i)` makes the regex case-insensitive. `1.0Alpha1` becomes `1.0a1`.
2. `^v?` strips leading `v` prefix. Developers often write `v1.0.0` in git tags.
3. `(\d+)` followed by `!` captures epoch. The `?` makes the whole `(?:...)?` group optional.
4. `\d+(?:\.\d+)*` matches release segments. `\d+` is the first segment (required), `(?:\.\d+)*` is zero or more additional `.N` segments.
5. The pre-release group matches `alpha`, `a`, `beta`, `b`, `preview`, `pre`, `c`, or `rc`, with optional separators (`-`, `_`, `.`), followed by optional number.
6. Post-release has two forms: explicit (`post3`) or implicit dash-number (`-3`).
7. Dev and local versions follow similar patterns.

**Why we do it this way:**
Single regex capture groups eliminate multiple string passes. Alternative would be splitting on `.` then checking each part, but that breaks on `1.0.post1.dev2` (which dot belongs to which component?).

**Alternative approaches:**
- Hand-written state machine: 3x the code, same functionality, no real performance gain
- String splitting on delimiters: Doesn't handle `-3` implicit post syntax or varied separators

### Step 3: Parse the Version String

In `internal/pypi/version.go:66-112`:

```go
func ParseVersion(s string) (Version, error) {
    normalized := strings.ToLower(strings.TrimSpace(s))
    m := versionRe.FindStringSubmatch(normalized)
    if m == nil {
        return Version{}, fmt.Errorf("%w: %q", ErrInvalidVersion, s)
    }

    v := Version{
        Raw:  s,
        Post: -1,  // Sentinel for "not present"
        Dev:  -1,
    }

    // m[1] is epoch
    if m[1] != "" {
        v.Epoch = mustAtoi(m[1])
    }

    // m[2] is release segments like "1.2.3"
    for _, seg := range strings.Split(m[2], ".") {
        v.Release = append(v.Release, mustAtoi(seg))
    }

    // m[3] is pre-release kind, m[4] is pre-release number
    if m[3] != "" {
        v.PreKind = normalizePreKind(m[3])  // "alpha" → "a", "preview" → "rc"
        v.PreNum = optionalAtoi(m[4])
    }

    // Post-release: explicit (m[5]/m[6]) or implicit dash-number (m[7])
    switch {
    case m[5] != "":
        v.Post = optionalAtoi(m[6])
    case m[7] != "":
        v.Post = mustAtoi(m[7])
    }

    // Dev release
    if m[8] != "" {
        v.Dev = optionalAtoi(m[9])
    }

    v.Local = m[10]

    return v, nil
}
```

**Key parts explained:**

**`mustAtoi()` and `optionalAtoi()`** (lines 242-250):
```go
func mustAtoi(s string) int {
    n, _ := strconv.Atoi(s)
    return n
}

func optionalAtoi(s string) int {
    if s == "" {
        return 0  // Implicit zero for "1.0a" → "1.0a0"
    }
    n, _ := strconv.Atoi(s)
    return n
}
```

These helpers ignore errors because the regex guarantees valid digits. If the regex matched, `\d+` captured only numeric characters.

**Normalization** (`normalizePreKind()` in lines 227-237):
```go
func normalizePreKind(s string) string {
    switch strings.ToLower(s) {
    case "a", "alpha":
        return "a"
    case "b", "beta":
        return "b"
    case "rc", "c", "pre", "preview":
        return "rc"
    default:
        return s
    }
}
```

PEP 440 allows `alpha`, `a`, `beta`, `b`, `c`, `rc`, `pre`, `preview` to all mean specific things. We normalize to canonical forms (`a`, `b`, `rc`) so comparison logic doesn't need to handle variants.

## Building the HTTP Client with Caching

### The Problem

angela queries PyPI's Simple API for version lists. A typical project has 20-50 dependencies. Without caching, you'd make 20-50 HTTP requests every time you run `angela check`. That's slow (5-10 seconds) and rude (hammers PyPI).

### The Solution

File-based cache with ETags. First request fetches and caches. Subsequent requests use `If-None-Match` header. If PyPI says "304 Not Modified", we use cached data.

### Implementation

In `internal/pypi/cache.go:20-36`:

```go
type Cache struct {
    dir string
    ttl time.Duration
}

type CacheEntry struct {
    ETag     string    `json:"etag"`
    Versions []string  `json:"versions"`
    CachedAt time.Time `json:"cached_at"`
}

func NewCache(dir string, ttl time.Duration) (*Cache, error) {
    if err := os.MkdirAll(dir, 0o750); err != nil {
        return nil, err
    }
    return &Cache{dir: dir, ttl: ttl}, nil
}
```

**Cache lookup** (lines 39-51):
```go
func (c *Cache) Get(key string) (*CacheEntry, bool) {
    data, err := os.ReadFile(c.path(key))
    if err != nil {
        return nil, false  // Cache miss
    }

    var entry CacheEntry
    if err := json.Unmarshal(data, &entry); err != nil {
        return nil, false  // Corrupt cache, treat as miss
    }
    return &entry, true
}
```

Notice we don't check TTL here. `Get()` returns whatever's in the file. The caller decides if it's fresh enough via `IsFresh()`.

**Freshness check** (lines 53-56):
```go
func (c *Cache) IsFresh(entry *CacheEntry) bool {
    return time.Since(entry.CachedAt) <= c.ttl
}
```

Simple time comparison. Default TTL is 1 hour (`internal/pypi/cache.go:11`).

**Cache write** (lines 58-77):
```go
func (c *Cache) Set(key string, entry *CacheEntry) error {
    data, err := json.Marshal(entry)
    if err != nil {
        return err
    }

    tmp, err := os.CreateTemp(c.dir, "tmp-*.json")
    if err != nil {
        return err
    }

    if _, writeErr := tmp.Write(data); writeErr != nil {
        _ = tmp.Close()
        _ = os.Remove(tmp.Name())
        return writeErr
    }
    _ = tmp.Close()

    return os.Rename(tmp.Name(), c.path(key))
}
```

Atomic write pattern: temp file + rename. If angela crashes mid-write, the original cache entry is untouched. `os.Rename()` is atomic on POSIX systems.

**Path traversal protection** (lines 85-88):
```go
func (c *Cache) path(key string) string {
    safe := filepath.Base(key)  // Strips directory separators
    return filepath.Join(c.dir, safe+".json")
}
```

Even if someone passes `../../../etc/passwd` as a package name, `filepath.Base()` returns just `passwd`, so the cache file goes in the cache directory as `passwd.json`. This prevents writing outside `~/.angela/cache/`.

### Using the Cache in the HTTP Client

In `internal/pypi/client.go:73-128`:

```go
func (c *Client) FetchVersions(ctx context.Context, name string) ([]string, error) {
    normalized := NormalizeName(name)

    // 1. Check cache
    entry, hit := c.cache.Get(normalized)
    if hit && c.cache.IsFresh(entry) {
        return entry.Versions, nil
    }

    // 2. Build request with ETag if we have one
    url := simpleAPIBase + normalized + "/"
    req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
    if err != nil {
        return nil, fmt.Errorf("build request for %s: %w", name, err)
    }
    req.Header.Set("Accept", simpleAPIAccept)
    req.Header.Set("User-Agent", c.userAgent)

    if entry != nil && entry.ETag != "" {
        req.Header.Set("If-None-Match", entry.ETag)
    }

    // 3. Make request with retry
    resp, err := c.doWithRetry(ctx, req)
    if err != nil {
        if entry != nil {
            return entry.Versions, nil  // Use stale cache on network error
        }
        return nil, fmt.Errorf("fetch %s: %w", name, err)
    }
    defer resp.Body.Close()

    // 4. Handle different status codes
    switch resp.StatusCode {
    case http.StatusNotModified:
        c.cache.Touch(normalized)  // Refresh TTL
        return entry.Versions, nil

    case http.StatusNotFound:
        return nil, fmt.Errorf("package %q not found on PyPI", name)

    case http.StatusOK:
        var result simpleAPIResponse
        if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
            return nil, fmt.Errorf("decode %s: %w", name, err)
        }
        _ = c.cache.Set(normalized, &CacheEntry{
            ETag:     resp.Header.Get("ETag"),
            Versions: result.Versions,
            CachedAt: time.Now(),
        })
        return result.Versions, nil

    default:
        return nil, fmt.Errorf("PyPI returned %d for %s", resp.StatusCode, name)
    }
}
```

**Why this specific handling:**

- `StatusNotModified (304)`: Data hasn't changed. Touch the cache to refresh TTL and return cached versions.
- `StatusNotFound (404)`: Package doesn't exist. Return error immediately, don't retry.
- `StatusOK (200)`: New data. Parse JSON, cache it, return to caller.
- `StatusInternalServerError (5xx)`: Server error. The retry logic in `doWithRetry()` handles this.

## Data Flow Example: Scanning for Vulnerabilities

Let's trace a complete request through the system.

**Scenario:** User runs `angela scan --file pyproject.toml`

### Request Comes In

Entry point: `cmd/angela/main.go:7-9`
```go
func main() {
    cli.Execute()
}
```

`Execute()` sets up Cobra commands in `internal/cli/update.go:57-83`:
```go
func Execute() {
    root := &cobra.Command{
        Use:   "angela",
        Short: "Python dependency updater and vulnerability scanner",
        // ...
    }

    root.AddCommand(
        newInitCmd(),
        newUpdateCmd(),
        newCheckCmd(),
        newScanCmd(),  // Our command
        newCacheCmd(),
    )

    if err := root.Execute(); err != nil {
        PrintError(err.Error())
        os.Exit(1)
    }
}
```

At this point:
- Cobra has parsed CLI arguments
- The `scan` command's `RunE` function has been identified
- Context is available via `cmd.Context()` for cancellation

### Processing Layer: runScan()

`internal/cli/update.go:403-440`:
```go
func runScan(ctx context.Context, file string) error {
    start := time.Now()
    cfg := config.Load(file)  // Load ignore lists, min-severity

    // 1. Parse dependency file
    deps, err := parseDeps(file)
    if err != nil {
        return err
    }

    // 2. Show spinner
    spin := ui.NewSpinner(fmt.Sprintf(
        "Scanning %d dependencies for vulnerabilities...",
        len(deps),
    ))
    spin.Start()

    // 3. Scan for vulnerabilities
    minSev := resolveMinSeverity(cfg.MinSeverity)
    vulns, scanErr := scanForVulns(ctx, deps)

    spin.Stop()

    if scanErr != nil {
        PrintError(scanErr.Error())
    }

    // 4. Filter results
    vulns = filterIgnoredVulns(vulns, cfg.IgnoreVulns)
    vulns = filterVulnsBySeverity(vulns, minSev)
    
    // 5. Print results
    PrintVulnerabilities(vulns)

    // 6. Print summary
    totalVulns := 0
    for _, vl := range vulns {
        totalVulns += len(vl)
    }

    PrintSummary(types.ScanResult{
        TotalPackages: len(deps),
        TotalVulns:    totalVulns,
        VulnsScanned:  true,
        Duration:      time.Since(start),
    }, false)

    return nil
}
```

This code:
- Loads user config to check if they've ignored specific CVEs or set a severity threshold
- Parses the dependency file to get package names and versions
- Shows a terminal spinner during the network-heavy scan
- Queries OSV.dev (this is where the real work happens)
- Filters results based on user config
- Formats and prints the vulnerability report

### Storage/Output: scanForVulns()

`internal/cli/update.go:352-372`:
```go
func scanForVulns(
    ctx context.Context,
    deps []types.Dependency,
) (map[string][]types.Vulnerability, error) {
    var queries []osv.PackageQuery
    for _, dep := range deps {
        ver := pyproject.ExtractMinVersion(dep.Spec)
        if ver == "" {
            continue  // Skip dependencies with no version specified
        }
        queries = append(queries, osv.PackageQuery{
            Name:    dep.Name,
            Version: ver,
        })
    }

    if len(queries) == 0 {
        return nil, nil
    }

    client := osv.NewClient()
    vulns, err := client.ScanPackages(ctx, queries)
    if err != nil {
        return nil, fmt.Errorf("vulnerability scan: %w", err)
    }
    return vulns, nil
}
```

The result is a map: `map[string][]types.Vulnerability` where the key is package name and value is all vulnerabilities affecting that package.

### OSV Client: Batch Query + Individual Fetch

`internal/osv/client.go:40-95`:
```go
func (c *Client) ScanPackages(
    ctx context.Context,
    packages []PackageQuery,
) (map[string][]types.Vulnerability, error) {
    // Step 1: Batch query for vulnerability IDs
    batch, err := c.queryBatch(ctx, packages)
    if err != nil {
        return nil, fmt.Errorf("osv batch query: %w", err)
    }

    // Step 2: Collect unique IDs
    allIDs := collectUniqueIDs(batch)
    if len(allIDs) == 0 {
        return nil, nil
    }

    // Step 3: Fetch full details for each vulnerability
    vulnMap, err := c.hydrateAll(ctx, allIDs)
    if err != nil {
        return nil, fmt.Errorf("osv hydrate: %w", err)
    }

    // Step 4: Build per-package results with deduplication
    return buildResults(packages, batch, vulnMap), nil
}
```

**queryBatch()** sends one POST to `https://api.osv.dev/v1/querybatch`:
```json
{
  "queries": [
    {"package": {"name": "requests", "ecosystem": "PyPI"}, "version": "2.28.0"},
    {"package": {"name": "django", "ecosystem": "PyPI"}, "version": "3.2.0"}
  ]
}
```

Response includes minimal vulnerability references:
```json
{
  "results": [
    {"vulns": [{"id": "GHSA-j8r2-6x86-q33q", "modified": "..."}]},
    {"vulns": [{"id": "CVE-2023-31047", "modified": "..."}]}
  ]
}
```

**hydrateAll()** then fetches full details for each unique ID using concurrent requests with `errgroup.SetLimit(15)`:

```go
func (c *Client) hydrateAll(
    ctx context.Context,
    ids []string,
) (map[string]*osvVuln, error) {
    var mu sync.Mutex
    result := make(map[string]*osvVuln, len(ids))

    g, ctx := errgroup.WithContext(ctx)
    g.SetLimit(maxHydrate)  // 15 concurrent requests

    for _, id := range ids {
        g.Go(func() (err error) {
            defer func() {
                if r := recover(); r != nil {
                    err = fmt.Errorf("panic hydrating %s: %v", id, r)
                }
            }()

            v, fetchErr := c.fetchVuln(ctx, id)
            if fetchErr != nil {
                return fetchErr
            }
            mu.Lock()
            result[id] = v
            mu.Unlock()
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return nil, err
    }
    return result, nil
}
```

Each `fetchVuln()` does: `GET https://api.osv.dev/v1/vulns/{id}`

The mutex protects the shared `result` map from concurrent writes.

## Error Handling Patterns

### Pattern 1: Retry with Exponential Backoff

When the network is flaky, retrying once might work. When PyPI is overloaded, retrying immediately makes it worse. Exponential backoff spaces out retries.

`internal/pypi/client.go:169-200`:
```go
func (c *Client) doWithRetry(
    ctx context.Context,
    req *http.Request,
) (*http.Response, error) {
    var lastErr error

    for attempt := range maxRetries {  // 0, 1, 2
        if attempt > 0 {
            shift := uint(attempt - 1)  // 0, 1
            delay := time.Duration(1<<shift) * baseRetryMs * time.Millisecond
            // delay is: 500ms, 1000ms
            select {
            case <-ctx.Done():
                return nil, ctx.Err()
            case <-time.After(delay):
            }
        }

        resp, err := c.http.Do(req)
        if err != nil {
            lastErr = err
            continue  // Network error, retry
        }

        if resp.StatusCode >= http.StatusInternalServerError {
            _ = resp.Body.Close()
            lastErr = fmt.Errorf("server error: %d", resp.StatusCode)
            continue  // Server error (5xx), retry
        }

        return resp, nil  // Success or client error (4xx), don't retry
    }

    return nil, fmt.Errorf("after %d attempts: %w", maxRetries, lastErr)
}
```

**Why this specific handling:**

The `1<<shift` bit shift doubles the delay each attempt. For `baseRetryMs=500`:
- Attempt 0: no delay
- Attempt 1: 500ms (2^0 * 500)
- Attempt 2: 1000ms (2^1 * 500)

The `select` respects context cancellation. If the user hits Ctrl+C while waiting, the retry aborts immediately instead of finishing the delay.

**What NOT to do:**
```go
// Bad: fixed delay doesn't respect overload
time.Sleep(1 * time.Second)

// Why this fails: If PyPI is overloaded, retrying after 1s adds more load.
// Exponential backoff gives the server time to recover.
```

### Pattern 2: Panic Recovery in Goroutines

An unrecovered panic in a goroutine kills the entire process. In a CLI tool, that means the user sees a stack trace instead of a proper error message.

`internal/pypi/client.go:144-156`:
```go
g.Go(func() (err error) {
    defer func() {
        if r := recover(); r != nil {
            err = fmt.Errorf("panic fetching %s: %v", name, r)
        }
    }()

    versions, fetchErr := c.FetchVersions(ctx, name)
    mu.Lock()
    results = append(results, FetchResult{
        Name: name, Versions: versions, Err: fetchErr,
    })
    mu.Unlock()
    return nil
})
```

The named return `(err error)` is crucial. Without it, the deferred function can't set the return value. This pattern converts panics into errors that flow through the normal error handling path.

## Performance Optimizations

### Before: Naive Sequential Requests

```go
// Don't do this
var results []FetchResult
for _, name := range names {
    versions, err := client.FetchVersions(ctx, name)
    results = append(results, FetchResult{Name: name, Versions: versions, Err: err})
}
```

For 50 dependencies at 200ms per request, this takes 10 seconds.

### After: Concurrent Requests with Bounded Workers

`internal/pypi/client.go:135-167`:
```go
func (c *Client) FetchAllVersions(
    ctx context.Context,
    names []string,
) []FetchResult {
    var (
        mu      sync.Mutex
        results = make([]FetchResult, 0, len(names))
    )

    g, ctx := errgroup.WithContext(ctx)
    g.SetLimit(c.maxWorkers)  // 10 concurrent requests

    for _, name := range names {
        g.Go(func() (err error) {
            defer func() {
                if r := recover(); r != nil {
                    err = fmt.Errorf("panic fetching %s: %v", name, r)
                }
            }()

            versions, fetchErr := c.FetchVersions(ctx, name)
            mu.Lock()
            results = append(results, FetchResult{
                Name: name, Versions: versions, Err: fetchErr,
            })
            mu.Unlock()
            return nil
        })
    }

    _ = g.Wait()
    return results
}
```

**What changed:**
- Spawn one goroutine per package, but only 10 run at a time
- Use mutex to protect shared `results` slice
- Panic recovery prevents one bad package from killing the scan

**Benchmarks:**
- Before (sequential): 10 seconds for 50 packages
- After (concurrent): 1-2 seconds for 50 packages (assuming cache misses)
- With cache hits: <100ms

## Configuration Management

### Loading Config

angela supports two config locations:
1. `.angela.toml` in current directory
2. `[tool.angela]` section in `pyproject.toml`

`internal/config/config.go:27-43`:
```go
func Load(pyprojectPath string) Config {
    // Try standalone config first
    if cfg, err := loadFile(".angela.toml"); err == nil {
        return cfg
    }

    // Fall back to [tool.angela] in pyproject.toml
    if cfg, ok := loadFromPyproject(pyprojectPath); ok {
        return cfg
    }

    return Config{}  // Empty config if none found
}
```

The `loadFromPyproject()` function uses a wrapper struct to extract the `[tool.angela]` section:

```go
type pyprojectWrapper struct {
    Tool struct {
        Angela Config `toml:"angela"`
    } `toml:"tool"`
}

func loadFromPyproject(path string) (Config, bool) {
    data, err := os.ReadFile(path)
    if err != nil {
        return Config{}, false
    }

    var wrapper pyprojectWrapper
    if err := toml.Unmarshal(data, &wrapper); err != nil {
        return Config{}, false
    }

    cfg := wrapper.Tool.Angela
    if cfg.MinSeverity == "" && len(cfg.Ignore) == 0 && len(cfg.IgnoreVulns) == 0 {
        return Config{}, false  // Empty config
    }

    return cfg, true
}
```

We validate before applying:
```go
cfg.MinSeverity = strings.ToLower(strings.TrimSpace(cfg.MinSeverity))
```

This normalizes `"CRITICAL"` and `"  critical  "` to `"critical"` for consistent comparison.

## Surgical TOML Editing

### The Challenge

Go's TOML libraries destroy comments and formatting when unmarshaling and re-marshaling. We need to update version specifiers without touching anything else.

### The Solution

Regex-based find/replace on raw bytes.

`internal/pyproject/writer.go:54-84`:
```go
func (u *Updater) UpdateDependency(pkg, newSpec string) error {
    for _, q := range []byte{'"', '\''} {  // Try both quote styles
        pattern := buildDepPattern(pkg, q)
        found := false
        u.content = pattern.ReplaceAllFunc(
            u.content,
            func(match []byte) []byte {
                found = true
                return replaceSpec(pattern, match, newSpec, q)
            },
        )
        if found {
            // Validate the edit didn't break TOML syntax
            var probe map[string]any
            if err := toml.Unmarshal(u.content, &probe); err != nil {
                return fmt.Errorf("update produced invalid TOML: %w", err)
            }
            return nil
        }
    }
    return fmt.Errorf("dependency %q not found", pkg)
}
```

The pattern matches the full dependency string:
```
"requests>=2.28.0"
```

Capture groups isolate:
1. Package name (`requests`)
2. Extras (`[async]` or empty)
3. Version spec (`>=2.28.0`)
4. Markers (`;python_version>='3.8'` or empty)

We replace only group 3:
```go
func replaceSpec(
    re *regexp.Regexp, match []byte, newSpec string, quote byte,
) []byte {
    groups := re.FindSubmatch(match)
    if len(groups) < 5 {
        return match  // Pattern didn't match expected structure
    }

    name := groups[1]
    extras := groups[2]
    markers := groups[4]

    var b []byte
    b = append(b, quote)
    b = append(b, name...)
    b = append(b, extras...)     // Keep extras
    b = append(b, []byte(newSpec)...)  // Replace version
    b = append(b, markers...)    // Keep markers
    b = append(b, quote)
    return b
}
```

Final result: `"requests>=2.32.3"` with the same quotes, extras, and markers as before.

## Testing This Feature

Test the TOML updater in `internal/pyproject/writer_test.go:11-34`:
```go
func TestUpdaterPreservesComments(t *testing.T) {
    const sampleTOML = `# Project configuration
[project]
dependencies = [
    "requests>=2.28.0",  # HTTP library
]`

    u, err := NewUpdater([]byte(sampleTOML))
    if err != nil {
        t.Fatalf("NewUpdater error: %v", err)
    }

    if err := u.UpdateDependency("requests", ">=2.31.0"); err != nil {
        t.Fatalf("UpdateDependency error: %v", err)
    }

    result := string(u.Bytes())

    if !strings.Contains(result, `"requests>=2.31.0"`) {
        t.Error("version was not updated")
    }
    if !strings.Contains(result, "# HTTP library") {
        t.Error("inline comment was lost")
    }
}
```

Expected output:
```toml
# Project configuration
[project]
dependencies = [
    "requests>=2.31.0",  # HTTP library
]
```

If you see `[2.31.0](file:///mnt/user-data/outputs)` instead, the regex is broken. If the comment is gone, something's unmarshaling/remarshaling instead of using regex surgery.

## Common Implementation Pitfalls

### Pitfall 1: Not Normalizing Package Names

**Symptom:**
User has `Django>=3.2.0` in their pyproject.toml, but angela says "package not found".

**Cause:**
```go
// Wrong: case-sensitive comparison
if dep.Name == "django" {
    // Won't match "Django"
}
```

**Fix:**
```go
// Correct: normalize before comparing
normalized := pypi.NormalizeName(dep.Name)  // "Django" → "django"
```

PEP 503 specifies package name normalization: lowercase, replace `[-_.]` with `-`. Both PyPI and angela must use the same normalization or lookups fail.

### Pitfall 2: Assuming Stable-Only Versions

**Symptom:**
User gets upgraded to `package==3.0a1` (an alpha pre-release).

**Cause:**
```go
// Wrong: picks any latest version
latest := versions[len(versions)-1]
```

**Fix:**
```go
// Correct: filter pre-releases
latest, err := pypi.LatestStable(versions)
```

The `LatestStable()` function skips any version with `PreKind != ""` or `Dev >= 0`.

### Pitfall 3: Ignoring Context Cancellation

**Symptom:**
User hits Ctrl+C, but angela keeps running for 10 more seconds.

**Cause:**
```go
// Wrong: doesn't respect context
time.Sleep(10 * time.Second)
```

**Fix:**
```go
// Correct: use select with context
select {
case <-ctx.Done():
    return ctx.Err()
case <-time.After(10 * time.Second):
}
```

Always pass `context.Context` through the call stack and check `ctx.Done()` in loops or sleeps.

## Debugging Tips

### Issue: Cache Always Misses

**Problem:** angela makes fresh HTTP requests every time, ignoring cache.

**How to debug:**
1. Check `~/.angela/cache/` for JSON files: `ls -lah ~/.angela/cache/`
2. Look at timestamps: `cat ~/.angela/cache/requests.json | jq '.cached_at'`
3. Check TTL: is `cached_at` more than 1 hour old?

**Common causes:**
- Cache directory doesn't exist (permissions issue)
- `CachedAt` time is in the future (system clock wrong)
- Package name normalization mismatch (cached as `Django.json` but looking for `django.json`)

### Issue: "Invalid TOML syntax" After Update

**Problem:** angela updates a dependency but produces broken TOML.

**How to debug:**
1. Look at the file before and after: `git diff pyproject.toml`
2. Try parsing with `toml.Unmarshal()` manually to see where it breaks
3. Check if the regex pattern matched something unexpected (like a comment containing the package name)

**Common causes:**
- Dependency appears multiple times (once in `dependencies`, once in `optional-dependencies["dev"]`)
- Package name appears in a comment: `# Note: requests is outdated`
- Malformed original TOML (broken quotes, unclosed brackets)

## Code Organization Principles

### Why pyproject/ is Separate from requirements/

```
internal/
├── pyproject/
│   ├── parser.go
│   └── writer.go
└── requirements/
    ├── parser.go
    └── writer.go
```

They're separate because:
- Different file formats (TOML vs plain text)
- Different parsing logic (toml.Unmarshal vs line-by-line scanning)
- Different update strategies (regex on TOML vs regex on plain text)

But they share the same interface:
```go
func ParseFile(path string) ([]types.Dependency, error)
func UpdateFile(path string, updates map[string]string) error
```

This makes the CLI layer generic. It doesn't care which format you use:

```go
func parseDeps(file string) ([]types.Dependency, error) {
    if isRequirementsTxt(file) {
        return requirements.ParseFile(file)
    }
    return pyproject.ParseFile(file)
}
```

### Naming Conventions

- `*Client` = Network client (PyPI, OSV)
- `Parse*` = Read and extract structured data
- `Update*` = Modify existing data
- `Fetch*` = Make HTTP request
- `Extract*` = Pull specific value from larger structure

Following these patterns makes it easier to find functionality. If you need to pull version numbers from a spec string, look for `Extract*`. If you need to make a network call, look for `Fetch*`.

## Extending the Code

### Adding Support for requirements.txt Comments

Currently angela preserves comments in pyproject.toml but not requirements.txt. Let's add it.

1. **Modify the parser** in `internal/requirements/parser.go:23-57`:

```go
// Add this field to track original line with comment
type dependencyLine struct {
    dep     types.Dependency
    comment string  // Text after # on the line
}

// Modify parseLine() to return both
func parseLine(s string) (types.Dependency, string) {
    var comment string
    if idx := strings.Index(s, " #"); idx >= 0 {
        comment = s[idx:]  // Store " # comment text"
        s = strings.TrimSpace(s[:idx])
    }
    // ... rest of parsing ...
    return dep, comment
}
```

2. **Update the writer** in `internal/requirements/writer.go:17-47`:

```go
// Preserve comments in regex replacement
func replaceSpec(
    re *regexp.Regexp, match []byte, newSpec string,
) []byte {
    groups := re.FindSubmatch(match)
    if len(groups) < 4 {
        return match
    }

    // Extract comment if present
    fullLine := string(match)
    var comment string
    if idx := strings.Index(fullLine, " #"); idx >= 0 {
        comment = fullLine[idx:]
    }

    var b []byte
    b = append(b, groups[1]...)  // Package name
    b = append(b, groups[2]...)  // Extras
    b = append(b, []byte(newSpec)...)  // New version
    b = append(b, []byte(comment)...)  // Preserve comment
    return b
}
```

3. **Add tests** in `internal/requirements/writer_test.go`:

```go
func TestUpdateFilePreservesComments(t *testing.T) {
    content := "requests>=2.28.0  # HTTP library\n"
    // ... write to temp file, update, check comment remains ...
}
```

This follows the same pattern as pyproject.toml comment preservation but adapted for the simpler requirements.txt format.

## Next Steps

You've seen how the code works. Now:

1. **Try the challenges** - [04-CHALLENGES.md](./04-CHALLENGES.md) has extension ideas like adding transitive dependency scanning, SBOM generation, and custom vulnerability sources
2. **Modify the cache TTL** - Change `DefaultCacheTTL` in `internal/pypi/cache.go:11` from 1 hour to 5 minutes and observe the cache behavior
3. **Add a new severity level** - Extend the severity classification in `internal/osv/client.go:262-270` to include "INFO" for low-priority advisories
