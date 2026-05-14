# System Architecture

This document breaks down how sentinel is designed and why certain architectural decisions were made.

## High Level Architecture

```
┌────────────────────────────────────────────────────────────┐
│                     CLI Layer (cobra)                       │
│  cmd/sentinel/main.go → internal/cli/root.go               │
│  Subcommands: scan, baseline save, baseline diff            │
│  Flags: --json, --min-severity, --root, --ignore-file       │
└──────────────────────────┬─────────────────────────────────┘
                           │
              ┌────────────┼────────────────┐
              ▼            ▼                ▼
┌──────────────────┐ ┌───────────┐ ┌──────────────────┐
│  Scanner Registry │ │  Config   │ │  Baseline        │
│  scanner.RunAll() │ │  Ignore   │ │  Save/Load/Diff  │
│  17 modules       │ │  List     │ │  JSON snapshots   │
│  parallel via     │ │  Filter   │ │                   │
│  errgroup         │ │           │ │                   │
└────────┬─────────┘ └─────┬─────┘ └─────────┬─────────┘
         │                 │                  │
         ▼                 ▼                  ▼
┌──────────────────────────────────────────────────────────┐
│              []types.Finding                              │
│  Scanner, Severity, Title, Path, Evidence, MITRE          │
└──────────────────────────┬───────────────────────────────┘
                           │
              ┌────────────┼────────────────┐
              ▼            ▼                ▼
┌──────────────────┐ ┌──────────┐ ┌──────────────────┐
│  Terminal Report  │ │  JSON    │ │  UI (banner,     │
│  Color-coded      │ │  Report  │ │  spinner, colors)│
│  severity groups  │ │  stdout  │ │                   │
└──────────────────┘ └──────────┘ └──────────────────┘
```

### Component Breakdown

**CLI Layer (internal/cli/)**
- Purpose: Parse flags, dispatch to scan or baseline workflows, format output
- Responsibilities: Flag validation, hostname detection, severity filtering, output mode selection
- Interfaces: Calls scanner.RunAll(), config.LoadIgnoreFile(), baseline.Save/Load/Diff()

**Scanner Registry (internal/scanner/scanner.go)**
- Purpose: Collect all scanner modules and run them in parallel
- Responsibilities: Registration at init time, goroutine coordination, result merging
- Interfaces: Exposes Register(), All(), and RunAll()

**Pattern Engine (internal/scanner/patterns.go)**
- Purpose: Centralized regex matching for suspicious content across all scanners
- Responsibilities: Compiled pattern definitions, severity ranking, single-function match API
- Interfaces: MatchLine() returns (matched, severity, label)

**Config (internal/config/)**
- Purpose: Load and apply ignore rules to suppress known-good findings
- Responsibilities: YAML-like file parsing, finding filtering by path/scanner/title

**Baseline (internal/baseline/)**
- Purpose: Persist scan results and compute diffs between snapshots
- Responsibilities: JSON serialization, composite-key deduplication

**Report (internal/report/)**
- Purpose: Render findings as colored terminal output or structured JSON
- Responsibilities: Severity sorting, color mapping, evidence truncation, summary statistics

**UI (internal/ui/)**
- Purpose: Terminal presentation (banner, spinner, colors, symbols)
- Responsibilities: ANSI color functions, braille spinner animation, cursor management

## Data Flow

### Scan Command Flow

Step by step walkthrough of what happens when the user runs `sentinel scan`:

```
1. main.go imports internal/scanner (blank import)
   All 17 scanner init() functions call Register()
   Registry now holds 17 Scanner implementations

2. cobra dispatches to runScan() in cli/scan.go
   Parses --min-severity, --root, --ignore-file flags
   Starts spinner if not in JSON mode

3. scanner.RunAll(root) launches 17 goroutines via errgroup
   Each goroutine calls scanner.Scan(root)
   Each scanner reads files under root, applies MatchLine()
   Findings collected under mutex into shared slice

4. config.LoadIgnoreFile() → ignoreList.Filter(findings)
   Removes any findings matching ignore rules

5. filterBySeverity(findings, minSev)
   Drops findings below the requested threshold

6. types.Tally(filtered) counts per-severity totals

7. report.PrintTerminal() or report.PrintJSON()
   Terminal: sort by severity descending, color-code, print summary
   JSON: encode ScanResult to stdout
```

### Baseline Diff Flow

```
1. baseline save: RunAll() → baseline.Save()
   Serializes findings + hostname + version to JSON file

2. baseline diff: baseline.Load() → RunAll() → baseline.Diff()
   Loads saved snapshot
   Runs fresh scan
   Builds map of known findings by scanner|path|title key
   Returns only findings not present in baseline

3. Apply ignore-list filter and severity filter
   Same pipeline as regular scan
```

## Design Patterns

### Scanner Registry Pattern

**What it is:**
A central registry that scanners add themselves to during package initialization, decoupling the registry from knowledge of specific scanner implementations.

**How it works:**

Each scanner module (systemd.go, cron.go, etc.) calls Register() in its init() function:

```go
func init() {
    Register(&SystemdScanner{})
}
```

The registry is just a slice:

```go
var registry []types.Scanner

func Register(s types.Scanner) {
    registry = append(registry, s)
}
```

The main.go entry point imports the scanner package with a blank import:

```go
import _ "github.com/CarterPerez-dev/sentinel/internal/scanner"
```

This triggers all init() functions in the scanner package, populating the registry before main() runs.

**Why we chose it:**
Adding a new scanner requires zero changes to existing code. Create the file, implement the Scanner interface, call Register() in init(). No switch statements, no factory functions, no configuration files. The Go compiler handles discovery.

**Trade-offs:**
- Pros: Zero-touch registration, impossible to forget to register (it's in the same file as the scanner)
- Cons: Init-time side effects, registration order depends on filename sort order (irrelevant since scanners run in parallel)

### Parallel Execution with errgroup

**What it is:**
All 17 scanners run concurrently in separate goroutines, coordinated by golang.org/x/sync/errgroup.

**How it works:**

```go
var (
    mu  sync.Mutex
    all []types.Finding
    g   errgroup.Group
)

for _, s := range registry {
    g.Go(func() error {
        results := s.Scan(root)
        mu.Lock()
        all = append(all, results...)
        mu.Unlock()
        return nil
    })
}

_ = g.Wait()
```

Each scanner goroutine independently reads its set of files, applies pattern matching, and collects findings. The mutex protects the shared findings slice. errgroup.Wait() blocks until all goroutines complete.

**Why we chose it:**
Scanners are I/O-bound (reading files from disk). Running them in parallel means the total scan time is roughly the time of the slowest scanner, not the sum of all 17. On a system with SSDs, this cuts scan time dramatically.

**Trade-offs:**
- Pros: Near-linear speedup for I/O-bound work, simple coordination
- Cons: Findings arrive in non-deterministic order (sorted before display)

### Severity-Ranked Pattern Matching

**What it is:**
A single function MatchLine() that tests a line of text against all 16 compiled patterns and returns the highest-severity match.

**How it works:**

```go
func MatchLine(line string) (matched bool, sev Severity, label string) {
    best := SeverityInfo
    for _, p := range SuspiciousPatterns {
        if p.Pattern.MatchString(line) {
            if !matched || p.Severity > best {
                best = p.Severity
                label = p.Label
            }
            matched = true
        }
    }
    return matched, best, label
}
```

When a line matches multiple patterns (a curl piped to bash matches both NetworkToolPattern and DownloadExecPattern), only the highest severity is reported. This prevents double-counting and ensures findings reflect the most dangerous interpretation.

**Why we chose it:**
Centralizing patterns means scanners don't duplicate regex definitions. Adding a new pattern to the engine automatically applies it everywhere: systemd, cron, profile, udev, and every other scanner that calls MatchLine().

## Layer Separation

```
┌────────────────────────────────────┐
│    Layer 1: pkg/types              │
│    - Domain types only             │
│    - No imports from internal      │
└────────────────────────────────────┘
           ↓
┌────────────────────────────────────┐
│    Layer 2: internal/scanner       │
│    - File I/O and pattern matching │
│    - Returns []types.Finding       │
│    - No knowledge of CLI or output │
└────────────────────────────────────┘
           ↓
┌────────────────────────────────────┐
│    Layer 3: internal/cli           │
│    - Orchestrates scan pipeline    │
│    - Applies filters               │
│    - Dispatches to report layer    │
└────────────────────────────────────┘
           ↓
┌────────────────────────────────────┐
│    Layer 4: internal/report + ui   │
│    - Presentation only             │
│    - Terminal colors, JSON encoding│
└────────────────────────────────────┘
```

### What Lives Where

**pkg/types:** Severity constants, Finding struct, ScanResult struct, Scanner interface. Imported by everything. Imports nothing internal.

**internal/scanner:** All 17 scanner implementations, pattern engine, filesystem helpers, registry. Imports only pkg/types. Has no knowledge of CLI flags, output format, or filtering.

**internal/config:** Ignore-list loading and filtering. Imports pkg/types.

**internal/baseline:** Snapshot persistence and diff computation. Imports pkg/types.

**internal/cli:** Cobra command definitions, flag parsing, scan orchestration. Imports scanner, config, baseline, report, ui.

**internal/report + ui:** Terminal formatting, JSON encoding, color functions, spinner. Imports pkg/types and ui.

## Data Models

### Finding

```go
type Finding struct {
    Scanner  string   `json:"scanner"`
    Severity Severity `json:"severity"`
    Title    string   `json:"title"`
    Path     string   `json:"path"`
    Evidence string   `json:"evidence"`
    MITRE    string   `json:"mitre"`
}
```

**Fields:**
- `Scanner`: Which module produced this finding ("systemd", "cron", "ssh", etc.)
- `Severity`: Enum from Info (0) to Critical (4), serializes as int in JSON
- `Title`: Human-readable description of what was found
- `Path`: Absolute filesystem path to the file containing the finding
- `Evidence`: The actual line or content that triggered the finding, truncated for display
- `MITRE`: ATT&CK technique ID (e.g., "T1543.002")

### ScanResult

```go
type ScanResult struct {
    Version    string        `json:"version"`
    ScanTime   time.Time     `json:"scan_time"`
    Hostname   string        `json:"hostname"`
    Findings   []Finding     `json:"findings"`
    Summary    SeverityCount `json:"summary"`
    DurationMs int64         `json:"duration_ms"`
}
```

This is the complete output of a scan, used by both the terminal renderer and JSON encoder. It includes metadata (version, hostname, timing) alongside the findings and pre-computed severity counts.

### Scanner Interface

```go
type Scanner interface {
    Name() string
    Scan(root string) []Finding
}
```

Every scanner module implements this two-method interface. Name() returns a human-readable identifier. Scan() takes a filesystem root path and returns all findings. The root parameter enables scanning mounted filesystems, chroots, or test fixture directories instead of the live system.

## Design Decisions

### Why a Flat Scanner Package Instead of Sub-Packages

All 17 scanners live in `internal/scanner/` as separate files in the same package. An alternative would be `internal/scanner/systemd/`, `internal/scanner/cron/`, etc.

**What we chose:** Single package with one file per scanner.

**Why:** Scanners share helpers (ReadLines, ListFiles, ResolveRoot, FindUserDirs, ScanFileForPatterns), the pattern engine (MatchLine, all compiled regexes), and the registry (Register). Putting them in separate packages would require exporting all of these or creating a shared utilities package. A single package keeps the shared code unexported and co-located.

**Trade-offs:** The scanner package has many files, but each file is self-contained and focused. The init() registration pattern means there's no central "list of scanners" to maintain.

### Why No External Dependencies for Scanning Logic

The scanner package uses only the standard library (os, path/filepath, strings, regexp, bufio) plus pkg/types. The only external dependencies are in the CLI and UI layers (cobra, fatih/color) and the concurrency layer (errgroup).

**Why:** The scanning logic must be trustworthy. External dependencies in the detection path could introduce supply chain risk. Keeping the core detection engine dependency-free means it can be audited by reading Go standard library code.

### Why Compiled Regexes in Package-Level Variables

Patterns like `ReverseShellPattern` and `DownloadExecPattern` are compiled once at package initialization as `var` declarations with `regexp.MustCompile()`. An alternative would be compiling them on first use or passing them as parameters.

**Why:** Regexes are compiled exactly once when the package loads. Every subsequent MatchLine() call uses the compiled automaton. Package-level vars are safe for concurrent reads, and all writes happen before main() runs.

## Extensibility

### Adding a New Scanner

1. Create a new file in internal/scanner/ (e.g., `docker.go`)
2. Define a struct that implements types.Scanner:
   ```go
   type DockerScanner struct{}

   func (d *DockerScanner) Name() string { return "docker" }
   func (d *DockerScanner) Scan(root string) []types.Finding { ... }
   ```
3. Register in init():
   ```go
   func init() { Register(&DockerScanner{}) }
   ```
4. Create test file `docker_test.go` with testdata fixtures

No other files need to change. The registry discovers it automatically.

### Adding a New Pattern

Add to `internal/scanner/patterns.go`:

```go
var NewPattern = regexp.MustCompile(`...`)
```

Add to the SuspiciousPatterns slice:

```go
{NewPattern, types.SeverityHigh, "description of what this detects"},
```

Every scanner that calls MatchLine() or ScanFileForPatterns() will immediately start checking for the new pattern.

## Key Files Reference

- `cmd/sentinel/main.go` - Entry point, blank import triggers scanner registration
- `pkg/types/types.go` - All domain types (Finding, Severity, Scanner interface)
- `internal/scanner/scanner.go` - Registry and parallel RunAll()
- `internal/scanner/patterns.go` - All 16 compiled regex patterns and MatchLine()
- `internal/scanner/helpers.go` - Shared filesystem utilities and ScanFileForPatterns()
- `internal/cli/root.go` - Cobra root command and global flags
- `internal/cli/scan.go` - Scan subcommand orchestration
- `internal/cli/baseline.go` - Baseline save/diff subcommands
- `internal/baseline/baseline.go` - JSON snapshot persistence and diff
- `internal/config/config.go` - Ignore-list loading and filtering

## Next Steps

Now that you understand the architecture:
1. Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for a walkthrough of the pattern engine, scanner implementations, and baseline diffing code
2. Try running `sentinel scan --root testdata` and trace the output back to the scanner source code to see the architecture in action
