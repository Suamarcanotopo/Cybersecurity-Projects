# Extension Challenges

You've built the base project. Now make it yours by extending it with new features.

These challenges are ordered by difficulty. Start with the easier ones to build confidence, then tackle the harder ones when you want to dive deeper.

## Easy Challenges

### Challenge 1: Add Color-Coded Severity Display

**What to build:**
Enhance the vulnerability output to show severity with background colors, not just text color.

**Why it's useful:**
When scanning 50 packages with 20+ vulnerabilities, CRITICAL issues should scream at you. Background red makes them impossible to miss.

**What you'll learn:**
- ANSI escape codes for background colors
- String formatting with mixed styles
- User experience design in terminal interfaces

**Hints:**
- Look at `internal/cli/output.go:228-248` where `severityColorFn()` chooses text colors
- The fatih/color package supports `color.BgRed` for background colors
- Don't forget to handle the case where `NO_COLOR` env var is set

**Test it works:**
Run `angela scan --file testdata/pyproject.toml` and verify CRITICAL vulnerabilities have red backgrounds while LOW vulnerabilities use normal colors.

### Challenge 2: Show Cache Hit Statistics

**What to build:**
Add a `stats` subcommand that shows cache hit/miss rates, cache size, and oldest/newest entries.

**Why it's useful:**
Helps users understand if their cache is working. If hit rate is <50%, maybe the TTL is too short.

**What you'll learn:**
- File system operations (reading directory, stat syscalls)
- Data aggregation and summary statistics
- Time formatting for human-readable output

**Implementation approach:**

1. **Add command** in `internal/cli/update.go`:
   ```go
   func newStatsCmd() *cobra.Command {
       return &cobra.Command{
           Use:   "stats",
           Short: "Show cache statistics",
           RunE: func(_ *cobra.Command, _ []string) error {
               return runStats()
           },
       }
   }
   ```

2. **Implement runStats()** that:
   - Lists all `.json` files in `~/.angela/cache/`
   - Parses each to get `cached_at` timestamp
   - Calculates: total entries, total size on disk, age distribution

3. **Format output** like:
   ```
   Cache Statistics
   ────────────────────────────────────
   Total entries:     42
   Cache size:        1.2 MB
   Oldest entry:      7 days ago (requests.json)
   Newest entry:      5 minutes ago (flask.json)
   Average age:       2 days 4 hours
   ```

**Hints:**
- Use `os.ReadDir()` to list cache directory
- `os.Stat()` gives you file size
- Parse `cached_at` with `time.Parse()` to calculate age
- The `internal/ui/` package has color helpers for pretty output

**Test it works:**
Run angela a few times with different packages, then `angela stats` should show increasing entry count.

### Challenge 3: Implement --json Output Mode

**What to build:**
Add a `--json` flag that outputs results as JSON instead of pretty terminal formatting.

**Real world application:**
CI/CD pipelines need machine-readable output. GitHub Actions can parse JSON to create annotations.

**What you'll learn:**
- JSON marshaling with custom structures
- Command line flag handling
- Adapting human-readable code for automation

**Implementation approach:**

1. **Add flag** to relevant commands:
   ```go
   var jsonOutput bool
   cmd.Flags().BoolVar(&jsonOutput, "json", false, "output as JSON")
   ```

2. **Create JSON structs** in `pkg/types/types.go`:
   ```go
   type JSONOutput struct {
       Updates         []UpdateResult      `json:"updates"`
       Vulnerabilities []VulnByPackage     `json:"vulnerabilities"`
       Summary         ScanResult          `json:"summary"`
   }
   
   type VulnByPackage struct {
       Package string          `json:"package"`
       Vulns   []Vulnerability `json:"vulnerabilities"`
   }
   ```

3. **Conditional output** in `internal/cli/output.go`:
   ```go
   if jsonOutput {
       data, _ := json.MarshalIndent(result, "", "  ")
       fmt.Println(string(data))
   } else {
       PrintUpdates(result.Updates)
       PrintVulnerabilities(result.Vulnerabilities)
       PrintSummary(result.Summary, updated)
   }
   ```

**Extra credit:**
Support `--json-compact` for single-line output (no indentation) suitable for log aggregation.

**Test it works:**
```bash
angela scan --file testdata/pyproject.toml --json | jq '.vulnerabilities[].package'
```

Should output package names as a JSON array.

## Intermediate Challenges

### Challenge 4: Add requirements.in Support

**What to build:**
Extend angela to handle requirements.in files (used by pip-tools for dependency compilation).

**Real world application:**
pip-tools workflow uses `requirements.in` for high-level dependencies and compiles to `requirements.txt`. angela should update the .in file, then users run `pip-compile` to regenerate .txt.

**What you'll learn:**
- Multiple file format support
- File type detection
- Code reuse across similar formats

**Implementation approach:**

1. **Detect file type** in `internal/cli/update.go:395-401`:
   ```go
   func isRequirementsIn(path string) bool {
       return strings.HasSuffix(strings.ToLower(path), ".in")
   }
   ```

2. **Reuse parser** - requirements.in uses the same syntax as requirements.txt:
   ```go
   func parseDeps(file string) ([]types.Dependency, error) {
       if isRequirementsTxt(file) || isRequirementsIn(file) {
           return requirements.ParseFile(file)
       }
       return pyproject.ParseFile(file)
   }
   ```

3. **Handle update differently** - After updating requirements.in, suggest running pip-compile:
   ```go
   if updated && isRequirementsIn(file) {
       fmt.Printf("\n  %s %s\n", 
           ui.HiYellow(ui.ArrowRight),
           ui.HiBlackItalic("Run 'pip-compile' to regenerate requirements.txt"))
   }
   ```

**Hints:**
- requirements.in and requirements.txt are identical formats
- The only difference is pip-tools reads .in and writes .txt
- angela should update .in, not .txt (which is auto-generated)

**Test it works:**
Create `test.in` with `requests>=2.28.0`, run `angela update --file test.in`, verify version bumped and file preserved comments.

### Challenge 5: Scan Transitive Dependencies

**What to build:**
Instead of only scanning packages in pyproject.toml, resolve the full dependency tree and scan everything.

**Why this is hard:**
Dependency resolution is complex. You need to:
- Parse version specifiers and find compatible versions
- Handle conflicting requirements (package A needs requests>=2.0, package B needs requests<3.0)
- Respect platform markers (some deps only on Windows)
- Deal with circular dependencies

**What you'll learn:**
- Dependency resolution algorithms (PubGrub, used by Poetry)
- Graph traversal and cycle detection
- Constraint satisfaction problems

**Implementation approach:**

1. **Research phase**
   - Read PEP 508 (dependency specifiers)
   - Study pip's resolver or Poetry's implementation
   - Understand PubGrub algorithm (https://github.com/pubgrub-rs/pubgrub)

2. **Design phase**
   - Decide: full PubGrub or simplified BFS resolver?
   - For beginner project: BFS with "first compatible version" is enough
   - Consider performance: caching version metadata is critical

3. **Implementation phase**
   - Start with `func ResolveTree(deps []Dependency) ([]Dependency, error)`
   - For each dep, fetch its dependencies from PyPI metadata
   - Recursively resolve until no new packages found
   - Deduplicate: if package appears multiple times, pick highest compatible version

4. **Testing phase**
   - Test with flask (has many transitive deps)
   - Verify circular deps don't cause infinite loops
   - Check conflicting requirements error clearly

**Gotchas:**
- PyPI's Simple API doesn't include dependency info. You need the JSON API: `https://pypi.org/pypi/{package}/json`
- Dependency resolution is NP-hard in the general case. Simplifications are necessary.
- Environment markers (`platform_system == "Windows"`) need evaluation

**Resources:**
- PEP 508: https://peps.python.org/pep-0508/
- Poetry resolver: https://github.com/python-poetry/poetry-core
- PubGrub paper: https://medium.com/@nex3/pubgrub-2fb6470504f

### Challenge 6: Generate SBOM (Software Bill of Materials)

**What to build:**
Add `angela sbom` command that outputs a CycloneDX or SPDX format SBOM.

**Why this is hard:**
SBOM formats are verbose and require data angela doesn't currently collect (license info, package hashes, component relationships).

**What you'll learn:**
- SBOM standards (CycloneDX 1.5, SPDX 2.3)
- Software supply chain security
- Structured data export

**Architecture changes needed:**

```
┌─────────────────────┐
│  angela sbom        │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐     ┌─────────────────────┐
│  Collect Metadata   │────▶│   PyPI JSON API    │
│  - License          │     │   /pypi/{pkg}/json │
│  - Author           │     └─────────────────────┘
│  - Hashes           │
│  - Dependencies     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Format as SBOM     │
│  - CycloneDX XML    │
│  - SPDX JSON        │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Output to File     │
└─────────────────────┘
```

**Implementation steps:**

1. **Add PyPI metadata fetcher** in `internal/pypi/metadata.go`:
   ```go
   type PackageMetadata struct {
       Name         string
       Version      string
       License      string
       Author       string
       HomePage     string
       SHA256Hash   string
       Dependencies []string
   }
   
   func (c *Client) FetchMetadata(ctx context.Context, name, version string) (*PackageMetadata, error) {
       url := fmt.Sprintf("https://pypi.org/pypi/%s/%s/json", name, version)
       // ... HTTP request, parse JSON ...
   }
   ```

2. **Create SBOM generator** in `internal/sbom/cyclonedx.go`:
   ```go
   func GenerateCycloneDX(deps []Dependency, metadata map[string]*PackageMetadata) ([]byte, error) {
       bom := CycloneDXBOM{
           BOMFormat:    "CycloneDX",
           SpecVersion:  "1.5",
           Version:      1,
           Components:   buildComponents(deps, metadata),
           Dependencies: buildDependencies(deps),
       }
       return xml.MarshalIndent(bom, "", "  ")
   }
   ```

3. **Add command** in `internal/cli/update.go`:
   ```go
   func newSBOMCmd() *cobra.Command {
       return &cobra.Command{
           Use:   "sbom",
           Short: "Generate Software Bill of Materials",
           RunE:  runSBOM,
       }
   }
   ```

**Success criteria:**
Your SBOM should:
- [ ] Include all direct dependencies
- [ ] Have license info for each package
- [ ] Provide SHA256 hashes for verification
- [ ] Link dependencies (A depends on B)
- [ ] Validate against CycloneDX schema

**Test it works:**
```bash
angela sbom --file pyproject.toml --output sbom.xml
cyclonedx validate sbom.xml
```

Should pass validation.

## Advanced Challenges

### Challenge 7: Implement Continuous Monitoring

**What to build:**
A daemon mode that watches pyproject.toml for changes and automatically checks for new vulnerabilities in the background.

**Estimated time:**
20-30 hours

**Prerequisites:**
Complete Challenges 2-4 first. This builds on JSON output, cache stats, and multiple file format support.

**What you'll learn:**
- File system watching with fsnotify
- Long-running daemon processes
- Signal handling for graceful shutdown
- Rate limiting to avoid hammering OSV.dev

**Planning this feature:**

Before you code, think through:
- How does the daemon start and stop? (systemd service? Background process?)
- What triggers a scan? (file change? Time interval? Both?)
- Where do results go? (Terminal? Log file? Webhook?)
- How do you prevent infinite loops if angela modifies the file it's watching?

**High level architecture:**

```
┌─────────────────────┐
│   angela daemon     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│   File Watcher      │  fsnotify on pyproject.toml
│   (debounce 5s)     │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Parse & Scan       │  Read deps, query OSV
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Notify on Changes  │  Log or webhook on new CVEs
└─────────────────────┘
```

**Implementation phases:**

**Phase 1: File Watching** (3-5 hours)
```go
watcher, err := fsnotify.NewWatcher()
defer watcher.Close()

err = watcher.Add("pyproject.toml")
if err != nil {
    log.Fatal(err)
}

for {
    select {
    case event := <-watcher.Events:
        if event.Op&fsnotify.Write == fsnotify.Write {
            log.Println("File modified:", event.Name)
            // Debounce: wait 5 seconds for more changes
            debounce(5*time.Second, scanFile)
        }
    case err := <-watcher.Errors:
        log.Println("Error:", err)
    }
}
```

**Phase 2: Background Scanning** (8-12 hours)
- Run scans without blocking the main loop
- Rate limit: don't scan more than once per minute
- Cache previous results to detect *new* vulnerabilities
- Store state in `~/.angela/daemon_state.json`

**Phase 3: Notifications** (4-6 hours)
- Log new CVEs to `~/.angela/daemon.log`
- Optional: webhook to Slack/Discord
- Optional: desktop notification via notify-send

**Phase 4: Signal Handling** (2-3 hours)
```go
sigChan := make(chan os.Signal, 1)
signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)

go func() {
    <-sigChan
    log.Println("Shutting down gracefully...")
    // Cancel ongoing scans
    // Close watcher
    // Write state to disk
    os.Exit(0)
}()
```

**Known challenges:**

1. **Debouncing file events**
   - Problem: Text editors trigger multiple Write events per save
   - Hint: Use a timer that resets on each event. Only scan after 5 seconds of quiet.

2. **Detecting new vulnerabilities vs old**
   - Problem: How do you know if CVE-2024-1234 is new or was already there?
   - Hint: Store previous scan results in `daemon_state.json`. Compare current vs previous.

3. **Daemon lifecycle management**
   - Problem: How does the user start/stop/restart the daemon?
   - Hint: `angela daemon start --background` forks and exits. `angela daemon stop` sends SIGTERM to PID file.

**Success criteria:**
Your daemon should:
- [ ] Watch pyproject.toml for modifications
- [ ] Scan automatically after file changes (debounced)
- [ ] Log new vulnerabilities as they're discovered
- [ ] Gracefully shutdown on SIGTERM
- [ ] Restart without losing state
- [ ] Rate limit to avoid hammering OSV.dev

### Challenge 8: Add Private Vulnerability Database Support

**What to build:**
Allow users to query custom vulnerability databases in addition to OSV.dev. Useful for enterprises with internal security advisories.

**Estimated time:**
15-25 hours

**Prerequisites:**
You should have a solid understanding of angela's OSV client and interface design.

**What you'll learn:**
- Plugin architecture and interfaces
- Database abstraction layers
- Configuration file parsing
- HTTP API design (if building the database server)

**Planning this feature:**

**Key design decision: interface definition**

```go
// pkg/vulnsource/source.go
type Source interface {
    // Name returns a unique identifier for this source
    Name() string
    
    // ScanPackages queries for vulnerabilities
    ScanPackages(ctx context.Context, packages []Package) (map[string][]Vulnerability, error)
    
    // IsReachable checks if the source is accessible
    IsReachable(ctx context.Context) error
}

// Default implementation
type OSVSource struct {
    client *osv.Client
}

func (s *OSVSource) ScanPackages(ctx context.Context, packages []Package) (map[string][]Vulnerability, error) {
    // Delegate to existing osv.Client
}
```

**Configuration format:**

```toml
[tool.angela]
# OSV.dev is always queried
# Additional sources:

[[tool.angela.vuln-sources]]
name = "company-internal"
url = "https://vulndb.company.com/api/v1"
api_key = "${COMPANY_VULNDB_KEY}"  # Read from env var
enabled = true

[[tool.angela.vuln-sources]]
name = "snyk"
url = "https://api.snyk.io/v1/test/pip"
api_key = "${SNYK_TOKEN}"
enabled = false  # Disabled
```

**Implementation phases:**

**Phase 1: Define Interface** (2-3 hours)
- Create `pkg/vulnsource/source.go` with the Source interface
- Implement OSVSource wrapper around existing osv.Client
- Write tests for interface compliance

**Phase 2: Config Parsing** (3-5 hours)
```go
type VulnSourceConfig struct {
    Name    string `toml:"name"`
    URL     string `toml:"url"`
    APIKey  string `toml:"api_key"`
    Enabled bool   `toml:"enabled"`
}

func (c *Config) LoadVulnSources() ([]vulnsource.Source, error) {
    var sources []vulnsource.Source
    
    // Always include OSV
    sources = append(sources, vulnsource.NewOSVSource())
    
    for _, cfg := range c.VulnSources {
        if !cfg.Enabled {
            continue
        }
        
        // Expand env vars in api_key
        apiKey := os.ExpandEnv(cfg.APIKey)
        
        source, err := vulnsource.NewHTTPSource(cfg.Name, cfg.URL, apiKey)
        if err != nil {
            return nil, err
        }
        
        sources = append(sources, source)
    }
    
    return sources, nil
}
```

**Phase 3: Generic HTTP Source** (5-8 hours)
```go
type HTTPSource struct {
    name   string
    url    string
    apiKey string
    client *http.Client
}

func (s *HTTPSource) ScanPackages(ctx context.Context, packages []Package) (map[string][]Vulnerability, error) {
    // Build request to custom API
    req, err := http.NewRequestWithContext(ctx, "POST", s.url+"/scan", body)
    req.Header.Set("Authorization", "Bearer "+s.apiKey)
    
    resp, err := s.client.Do(req)
    // ... parse response ...
    
    // Normalize response format to match angela's Vulnerability struct
    return normalizeVulns(resp), nil
}
```

**Phase 4: Merge Results** (3-4 hours)
```go
func scanAllSources(ctx context.Context, sources []Source, packages []Package) (map[string][]Vulnerability, error) {
    allVulns := make(map[string][]Vulnerability)
    var mu sync.Mutex
    
    g, ctx := errgroup.WithContext(ctx)
    
    for _, src := range sources {
        g.Go(func() error {
            vulns, err := src.ScanPackages(ctx, packages)
            if err != nil {
                log.Printf("Source %s failed: %v", src.Name(), err)
                return nil  // Don't fail entire scan
            }
            
            mu.Lock()
            defer mu.Unlock()
            
            // Merge results, dedup by ID
            for pkg, vlist := range vulns {
                allVulns[pkg] = append(allVulns[pkg], vlist...)
            }
            
            return nil
        })
    }
    
    _ = g.Wait()
    
    // Deduplicate across sources
    for pkg := range allVulns {
        allVulns[pkg] = deduplicateVulns(allVulns[pkg])
    }
    
    return allVulns, nil
}
```

**Testing strategy:**
- Unit test: Mock Source implementation that returns fake vulns
- Integration test: Stand up test HTTP server that mimics custom vuln DB
- End-to-end test: Query real OSV.dev + test server, verify results merged

**Success criteria:**
- [ ] Can query multiple vulnerability sources concurrently
- [ ] Results are deduplicated by CVE ID
- [ ] API keys loaded from environment variables
- [ ] Failure of one source doesn't block others
- [ ] Configuration validates (rejects malformed URLs, missing API keys)

## Performance Challenges

### Challenge: Handle 10,000+ Packages

**The goal:**
Make angela fast enough to scan monorepo dependency lists with thousands of packages.

**Current bottleneck:**
OSV.dev batch endpoint accepts max 1000 packages per request. For 10,000 packages, you need 10 requests. Each takes 2-5 seconds. Sequential = 20-50 seconds total.

**Optimization approaches:**

**Approach 1: Concurrent Batch Requests**
```go
func (c *Client) ScanPackagesBatched(ctx context.Context, packages []PackageQuery) (map[string][]Vulnerability, error) {
    const batchSize = 1000
    batches := chunkPackages(packages, batchSize)
    
    var mu sync.Mutex
    allVulns := make(map[string][]Vulnerability)
    
    g, ctx := errgroup.WithContext(ctx)
    g.SetLimit(5)  // Max 5 concurrent batch requests
    
    for _, batch := range batches {
        g.Go(func() error {
            vulns, err := c.ScanPackages(ctx, batch)
            if err != nil {
                return err
            }
            
            mu.Lock()
            for pkg, vlist := range vulns {
                allVulns[pkg] = append(allVulns[pkg], vlist...)
            }
            mu.Unlock()
            
            return nil
        })
    }
    
    if err := g.Wait(); err != nil {
        return nil, err
    }
    
    return allVulns, nil
}
```

- Gain: 5x speedup (5 batches in parallel)
- Tradeoff: Higher memory usage, more aggressive API usage

**Approach 2: Local Vulnerability Database Cache**

Download OSV.dev's entire vulnerability database (it's public) and query locally:

```bash
wget https://osv-vulnerabilities.storage.googleapis.com/PyPI/all.zip
unzip all.zip -d ~/.angela/vulndb/
```

Then search JSON files locally instead of hitting the API:

```go
func (c *LocalDB) FindVulns(pkg, version string) ([]Vulnerability, error) {
    files, _ := filepath.Glob(c.dir + "/*.json")
    
    var vulns []Vulnerability
    for _, f := range files {
        vuln := parseVulnFile(f)
        if affects(vuln, pkg, version) {
            vulns = append(vulns, vuln)
        }
    }
    return vulns, nil
}
```

- Gain: 100x speedup (no network), unlimited scale
- Tradeoff: 500MB disk space, need periodic updates

**Benchmark it:**
```bash
# Before optimization
time angela scan --file huge-project.toml
# real    0m42.318s

# After approach 1
time angela scan --file huge-project.toml
# real    0m8.942s

# After approach 2
time angela scan --file huge-project.toml
# real    0m0.431s
```

Target metrics:
- 1,000 packages: <5 seconds
- 10,000 packages: <30 seconds (approach 1) or <5 seconds (approach 2)

## Security Challenges

### Challenge: Verify Package Signatures

**What to implement:**
Before trusting PyPI version data, verify it's signed by PyPI's key.

**Threat model:**
This protects against:
- Man-in-the-middle attacks on PyPI requests
- Compromised CDN or DNS poisoning
- Malicious proxy intercepting and modifying responses

**Implementation:**

1. **Download PyPI's public key** from https://pypi.org/simple/.well-known/
2. **Verify response signature** using PGP or similar
3. **Reject unsigned or incorrectly signed data**

This is a deep challenge requiring understanding of:
- PGP signatures
- Trust chains and key verification
- Binary data handling in Go

PyPI doesn't currently sign Simple API responses (as of 2024), so you might need to implement this for a hypothetical future where they do, or design your own signature scheme for private PyPI mirrors.

### Challenge: Pass OWASP Dependency-Check Standards

**The goal:**
Make angela compliant with OWASP Dependency-Check's requirements for SCA tools.

**Current gaps:**
- No transitive dependency scanning
- No CWE categorization
- No CVSS score reporting
- No suppression file format

**Remediation:**

1. **Add CWE mapping** - OSV data includes CWE IDs in some advisories. Extract and display:
   ```
   CVE-2023-32681 (CWE-113: Improper Neutralization of CRLF Sequences)
   ```

2. **Report CVSS scores** - Extract from OSV severity field:
   ```
   CVSS v3.1: 9.8 (CRITICAL)
   Vector: CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H
   ```

3. **Suppression file** - Support dependency-check XML format:
   ```xml
   <suppressions>
     <suppress>
       <cve>CVE-2023-1234</cve>
       <reason>False positive - doesn't affect our use case</reason>
     </suppress>
   </suppressions>
   ```

4. **Generate HTML report** - Match dependency-check's report format for compatibility with existing tooling.

## Mix and Match

Combine features for bigger projects:

**Project Idea 1: Full Supply Chain Analyzer**
- Combine Challenge 5 (transitive deps) + Challenge 6 (SBOM generation) + Challenge 8 (private vuln DB)
- Result: Enterprise-grade dependency scanner that maps entire supply chain, generates SBOMs, and queries internal vulnerability databases

**Project Idea 2: CI/CD Integration Suite**
- Combine Challenge 3 (JSON output) + Challenge 7 (daemon mode) + Challenge 4 (requirements.in)
- Result: Continuous monitoring system that integrates with GitHub Actions, outputs structured data for annotations, and supports all Python dependency formats

## Real World Integration Challenges

### Integrate with GitHub Security Advisories

**The goal:**
Make angela fetch vulnerability data from GitHub's GraphQL API in addition to OSV.dev.

**What you'll need:**
- GitHub personal access token with `security_events` scope
- GraphQL client library (e.g., `github.com/shurcooL/graphql`)
- Understanding of GitHub's vulnerability schema

**Implementation plan:**

1. **Set up GraphQL client**:
   ```go
   import "github.com/shurcooL/graphql"
   
   client := graphql.NewClient(
       "https://api.github.com/graphql",
       oauth2Client,
   )
   ```

2. **Query for advisories**:
   ```go
   var query struct {
       SecurityAdvisories struct {
           Nodes []struct {
               GHSAID      string
               Severity    string
               Description string
               // ...
           }
       } `graphql:"securityAdvisories(ecosystem: PIP, first: 100)"`
   }
   ```

3. **Convert to angela's Vulnerability format**
4. **Merge with OSV results**

**Watch out for:**
- Rate limits (5000 queries/hour for authenticated requests)
- Pagination (GitHub returns max 100 results per query)
- Different severity scales (GitHub uses LOW/MODERATE/HIGH/CRITICAL, same as OSV)

### Deploy as Lambda Function

**The goal:**
Run angela as an AWS Lambda that scans repositories on webhook events.

**What you'll learn:**
- Serverless architecture
- Cold start optimization
- Lambda event handling

**Steps:**

1. **Containerize angela**:
   ```dockerfile
   FROM golang:1.24 AS build
   WORKDIR /app
   COPY . .
   RUN go build -o angela ./cmd/angela
   
   FROM public.ecr.aws/lambda/provided:al2
   COPY --from=build /app/angela /var/task/angela
   ENTRYPOINT ["/var/task/angela"]
   ```

2. **Handle Lambda events**:
   ```go
   func handler(ctx context.Context, event S3Event) error {
       // Download pyproject.toml from S3
       // Run angela scan
       // Upload results back to S3
   }
   ```

3. **Deploy**:
   ```bash
   sam build
   sam deploy --guided
   ```

**Production checklist:**
- [ ] Cache layer for PyPI responses (use ElastiCache or S3)
- [ ] Timeout handling (Lambda max is 15 minutes)
- [ ] Memory tuning (profile with 512MB, 1024MB, 2048MB)
- [ ] Error alerting (CloudWatch alarms)

## Contribution Ideas

Finished a challenge? Share it back:

1. **Fork the repo** at github.com/CarterPerez-dev/angela
2. **Implement your extension** in a feature branch
3. **Document it** - update learn/ folder with your changes
4. **Submit a PR** with:
   - Implementation
   - Tests (minimum 80% coverage)
   - Documentation
   - Example usage

Good extensions might get merged into the main project.

## Challenge Yourself Further

### Build Something New

Use the concepts you learned here to build:

**angela-watch** - Real-time dependency security monitor that opens GitHub issues when new CVEs appear. Combines file watching, GitHub API integration, and vulnerability scanning.

**angela-diff** - Compare two branches/commits to see which dependencies changed and what security impact that has. Useful for pull request reviews.

**angela-policy** - Policy as code engine. Define rules like "no dependencies with CRITICAL vulnerabilities" or "all deps must be updated within 30 days of release". angela-policy enforces these in CI/CD.

### Study Real Implementations

Compare your implementation to production tools:

**Dependabot** (https://github.com/dependabot/dependabot-core)
- How they handle transitive dependencies
- Their version resolution strategy
- Ruby-based, supports 20+ ecosystems

**pip-audit** (https://github.com/pypa/pip-audit)
- Uses OSV.dev like angela
- Python implementation
- Integrates with pip's resolver

**Snyk** (closed source, but read their docs)
- How they prioritize vulnerabilities
- Their fix suggestions and auto-PR workflow
- Proprietary database vs OSV aggregation

Read their code, understand their tradeoffs, steal their good ideas.

### Write About It

Document your extension:

**Blog post**: "I Added Transitive Dependency Scanning to a Vulnerability Scanner"
- What you built
- Technical challenges you hit
- Performance benchmarks before/after
- Code snippets with explanations

**Tutorial**: "Building a Python Dependency Scanner in Go"
- Step by step guide replicating angela
- Explain each component
- Include exercises

**Comparison**: "angela vs pip-audit vs Snyk"
- Feature matrix
- Performance comparison
- When to use which tool

Teaching others is the best way to verify you understand it.

## Getting Help

Stuck on a challenge?

1. **Debug systematically**
   - What did you expect to happen?
   - What actually happened?
   - What's the smallest code change that reproduces it?

2. **Read the existing code**
   - How does angela handle similar problems?
   - The OSV client does concurrent requests - can you adapt that pattern?

3. **Search for similar problems**
   - StackOverflow: `[go] http client retry logic`
   - GitHub Issues: how did other projects solve this?

4. **Ask for help**
   - Open a GitHub Discussion with:
     - What you're trying to build
     - What you've tried so far
     - Specific error messages or unexpected behavior
     - Minimal code example

Don't just paste error messages. Explain your understanding of what *should* happen and why it's not working.

## Challenge Completion Tracker

Track your progress:

- [ ] Easy Challenge 1: Color-Coded Severity
- [ ] Easy Challenge 2: Cache Statistics
- [ ] Easy Challenge 3: JSON Output Mode
- [ ] Intermediate Challenge 4: requirements.in Support
- [ ] Intermediate Challenge 5: Transitive Dependencies
- [ ] Intermediate Challenge 6: SBOM Generation
- [ ] Advanced Challenge 7: Continuous Monitoring
- [ ] Advanced Challenge 8: Private Vulnerability DB
- [ ] Performance: 10,000+ Packages
- [ ] Security: Package Signature Verification

Completed all of them? You've mastered dependency scanning. Time to build something new or contribute back to open source projects that need better security tooling.
