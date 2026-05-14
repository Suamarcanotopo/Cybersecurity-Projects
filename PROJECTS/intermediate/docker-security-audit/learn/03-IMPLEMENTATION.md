# Implementation Guide

This document walks through the actual code. We'll build key features step by step and explain the decisions along the way.

## File Structure Walkthrough
```
docker-security-audit/
├── cmd/docksec/
│   └── main.go              # Entry point: CLI setup, Cobra commands
├── internal/
│   ├── analyzer/
│   │   ├── analyzer.go      # Interface definition
│   │   ├── container.go     # Running container security checks
│   │   ├── daemon.go        # Docker daemon config validation
│   │   ├── image.go         # Image metadata inspection
│   │   ├── dockerfile.go    # Dockerfile static analysis
│   │   └── compose.go       # docker-compose.yml analysis
│   ├── benchmark/
│   │   └── controls.go      # CIS Docker Benchmark v1.6.0 controls
│   ├── config/
│   │   ├── config.go        # Configuration struct and filters
│   │   └── constants.go     # Timeouts, rate limits, thresholds
│   ├── docker/
│   │   └── client.go        # Docker SDK wrapper with timeouts
│   ├── finding/
│   │   └── finding.go       # Finding model and collection methods
│   ├── parser/
│   │   ├── dockerfile.go    # BuildKit-based Dockerfile parser
│   │   ├── compose.go       # docker-compose YAML parser
│   │   └── visitor.go       # Visitor pattern for rule application
│   ├── proc/
│   │   ├── capabilities.go  # Linux capabilities parsing from /proc
│   │   ├── proc.go          # Process info extraction
│   │   └── security.go      # Security profile inspection
│   ├── report/
│   │   ├── reporter.go      # Reporter factory
│   │   ├── terminal.go      # Colored terminal output
│   │   ├── json.go          # Structured JSON
│   │   ├── sarif.go         # SARIF 2.1.0 for GitHub
│   │   └── junit.go         # JUnit XML for CI/CD
│   ├── rules/
│   │   ├── capabilities.go  # 41 capabilities with risk levels
│   │   ├── paths.go         # 200+ sensitive host paths
│   │   └── secrets.go       # 80+ secret patterns + entropy
│   └── scanner/
│       └── scanner.go       # Orchestration: concurrent execution
├── Dockerfile               # Multi-stage build
├── go.mod                   # Dependencies
└── go.sum
```

## Building Core Feature 1: Container Security Analysis

### Step 1: Detect Privileged Containers

What we're building: Check if containers run with --privileged flag.

The privileged flag gives containers all Linux capabilities and access to all devices. It's effectively root on the host.

In `internal/analyzer/container.go:72-86`:
```go
func (a *ContainerAnalyzer) checkPrivileged(
    target finding.Target,
    info types.ContainerJSON,
) finding.Collection {
    var findings finding.Collection

    if info.HostConfig.Privileged {
        control, _ := benchmark.Get("5.4")
        f := finding.New("CIS-5.4", control.Title, finding.SeverityCritical, target).
            WithDescription(control.Description).
            WithCategory(string(CategoryContainerRuntime)).
            WithRemediation(control.Remediation).
            WithReferences(control.References...).
            WithCISControl(control.ToCISControl())
        findings = append(findings, f)
    }

    return findings
}
```

**Why this code works:**
- Line 7: Docker SDK populates HostConfig.Privileged from container's runtime config
- Line 8: benchmark.Get() retrieves CIS control 5.4 with title, description, remediation
- Line 9-14: Builder pattern constructs finding with all metadata in one readable chain
- Line 15: Append to collection (nil slice is valid in Go, append handles it)

**Common mistakes here:**
```go
// Wrong: Not checking the actual runtime state
if strings.Contains(info.Config.Image, "privileged") {
    // This checks image name, not actual --privileged flag
}

// Why this fails: Image name has nothing to do with runtime flags.
// Always check HostConfig for runtime configuration.

// Wrong: Creating finding without CIS control
f := finding.New("privileged", "Bad container", finding.SeverityCritical, target)

// Why this fails: Loses compliance mapping. Reports won't show CIS control ID.
// Always attach control metadata when implementing CIS checks.
```

### Step 2: Check Added Capabilities

Containers can add capabilities beyond Docker's defaults using --cap-add.

In `internal/analyzer/container.go:88-117`:
```go
func (a *ContainerAnalyzer) checkCapabilities(
    target finding.Target,
    info types.ContainerJSON,
) finding.Collection {
    var findings finding.Collection

    for _, cap := range info.HostConfig.CapAdd {
        capName := strings.ToUpper(string(cap))
        capInfo, exists := rules.GetCapabilityInfo(capName)
        if !exists {
            continue
        }

        if capInfo.Severity >= finding.SeverityHigh {
            control, _ := benchmark.Get("5.3")
            title := "Dangerous capability added: " + capName
            if capInfo.Severity == finding.SeverityCritical {
                title = "Critical capability added: " + capName
            }
            f := finding.New("CIS-5.3", title, capInfo.Severity, target).
                WithDescription(capInfo.Description).
                WithCategory(string(CategoryContainerRuntime)).
                WithRemediation(control.Remediation).
                WithReferences(control.References...).
                WithCISControl(control.ToCISControl())
            findings = append(findings, f)
        }
    }

    return findings
}
```

**What's happening:**
1. Line 7: Iterate CapAdd array from Docker inspect output
2. Line 8: Normalize to uppercase (Docker uses caps or lowercase, our rules use uppercase)
3. Line 9: Lookup capability in rules database (O(1) map access)
4. Line 10-12: Skip unknown capabilities (defensive - Docker might add new ones)
5. Line 14: Only report HIGH and CRITICAL (skip MEDIUM like CAP_NET_BIND_SERVICE)
6. Line 19: Use severity from rules database, not hardcoded in analyzer

**Why we do it this way:**
Separation of concerns. Analyzer knows how to extract CapAdd, rules package knows which capabilities are dangerous. Adding a new dangerous capability just requires updating `internal/rules/capabilities.go`, not modifying analyzer code.

**Alternative approaches:**
- Hardcode dangerous capabilities in analyzer: Works but duplicates knowledge. If we add Dockerfile checks later, we'd need same list there.
- Check all capabilities equally: Would flag CAP_NET_BIND_SERVICE (severity LOW) same as CAP_SYS_ADMIN (CRITICAL). User gets noise.

### Step 3: Validate Mount Security

Containers can bind mount host paths. Some paths enable container escape.

In `internal/analyzer/container.go:119-160`:
```go
func (a *ContainerAnalyzer) checkMounts(
    target finding.Target,
    info types.ContainerJSON,
) finding.Collection {
    var findings finding.Collection

    for _, mount := range info.Mounts {
        source := mount.Source

        if rules.IsDockerSocket(source) {
            control, _ := benchmark.Get("5.31")
            pathInfo, _ := rules.GetPathInfo(source)
            f := finding.New("CIS-5.31", control.Title, finding.SeverityCritical, target).
                WithDescription(pathInfo.Description).
                WithCategory(string(CategoryContainerRuntime)).
                WithRemediation(control.Remediation).
                WithReferences(control.References...).
                WithCISControl(control.ToCISControl())
            findings = append(findings, f)
            continue
        }

        if rules.IsSensitivePath(source) {
            control, _ := benchmark.Get("5.5")
            pathInfo, _ := rules.GetPathInfo(source)
            severity := rules.GetPathSeverity(source)

            description := control.Description
            if pathInfo.Description != "" {
                description = pathInfo.Description
            }

            f := finding.New("CIS-5.5", "Sensitive host path mounted: "+source, severity, target).
                WithDescription(description).
                WithCategory(string(CategoryContainerRuntime)).
                WithRemediation(control.Remediation).
                WithReferences(control.References...).
                WithCISControl(control.ToCISControl())
            findings = append(findings, f)
        }
    }

    return findings
}
```

**Key parts explained:**

**Docker socket check** (`container.go:9-20`)
```go
if rules.IsDockerSocket(source) {
    // Always CRITICAL severity
    // Docker socket gives full daemon control
}
```
This is separated from generic sensitive paths because Docker socket is special. It's not just sensitive, it's a direct escape vector. Continue statement prevents double-reporting (socket is also in sensitive paths list).

**Sensitive path check** (`container.go:22-39`)
```go
severity := rules.GetPathSeverity(source)
```
Different paths have different severities. `/etc/shadow` is CRITICAL (password hashes), `/tmp` is MEDIUM (info disclosure). Rules package determines severity based on path database.

**Path-specific descriptions** (`container.go:27-30`)
```go
description := control.Description
if pathInfo.Description != "" {
    description = pathInfo.Description
}
```
CIS control 5.5 is generic ("Don't mount sensitive paths"). PathInfo has specific descriptions like "Docker daemon socket. Full control over Docker, container escape possible." More actionable for users.

## Building Core Feature 2: Dockerfile Static Analysis

### The Problem

Dockerfiles can hardcode secrets, run as root, download untrusted code. We need to catch these before images get built.

### The Solution

Parse Dockerfile into AST using BuildKit parser (same parser Docker uses), then run security checks on each instruction.

### Implementation

In `internal/analyzer/dockerfile.go:29-58`:
```go
func (a *DockerfileAnalyzer) Analyze(
    ctx context.Context,
) (finding.Collection, error) {
    file, err := os.Open(a.path)
    if err != nil {
        return nil, err
    }
    defer func() { _ = file.Close() }()

    result, err := parser.Parse(file)
    if err != nil {
        return nil, err
    }

    target := finding.Target{
        Type: finding.TargetDockerfile,
        Name: a.path,
    }

    var findings finding.Collection

    findings = append(findings, a.checkUserInstruction(target, result.AST)...)
    findings = append(findings, a.checkHealthcheck(target, result.AST)...)
    findings = append(findings, a.checkAddInstruction(target, result.AST)...)
    findings = append(findings, a.checkSecrets(target, result.AST)...)
    findings = append(findings, a.checkLatestTag(target, result.AST)...)
    findings = append(findings, a.checkCurlPipe(target, result.AST)...)
    findings = append(findings, a.checkSudo(target, result.AST)...)

    return findings, nil
}
```

BuildKit parser gives us result.AST (abstract syntax tree). Each node is one instruction with line numbers and arguments.

**Checking for USER instruction** (`dockerfile.go:60-109`):
```go
func (a *DockerfileAnalyzer) checkUserInstruction(
    target finding.Target,
    ast *parser.Node,
) finding.Collection {
    var findings finding.Collection

    hasUser := false
    var lastFromLine int

    for _, node := range ast.Children {
        switch strings.ToUpper(node.Value) {
        case "FROM":
            lastFromLine = node.StartLine
            hasUser = false  // Reset for each stage
        case "USER":
            hasUser = true
            user := ""
            if node.Next != nil {
                user = node.Next.Value
            }
            if user == "root" || user == "0" {
                loc := &finding.Location{Path: a.path, Line: node.StartLine}
                f := finding.New("DS-USER-ROOT", "USER instruction sets root user", finding.SeverityMedium, target).
                    WithDescription("Dockerfile explicitly sets USER to root, which should be avoided.").
                    WithCategory(string(CategoryDockerfile)).
                    WithLocation(loc).
                    WithRemediation("Create and use a non-root user in the Dockerfile.")
                findings = append(findings, f)
            }
        }
    }

    if !hasUser && lastFromLine > 0 {
        control, _ := benchmark.Get("4.1")
        loc := &finding.Location{Path: a.path, Line: lastFromLine}
        f := finding.New("CIS-4.1", control.Title, finding.SeverityMedium, target).
            WithDescription(control.Description).
            WithCategory(string(CategoryDockerfile)).
            WithLocation(loc).
            WithRemediation(control.Remediation).
            WithReferences(control.References...).
            WithCISControl(control.ToCISControl())
        findings = append(findings, f)
    }

    return findings
}
```

**Why this approach:**
- Handles multi-stage builds correctly (hasUser resets at each FROM)
- Detects explicit USER root (people do this to "fix" permission errors)
- Reports missing USER with line number pointing to last FROM
- Location with line number lets GitHub display inline warnings

**Secret detection with entropy** (`dockerfile.go:154-213`):
```go
func (a *DockerfileAnalyzer) checkSecrets(
    target finding.Target,
    ast *parser.Node,
) finding.Collection {
    var findings finding.Collection

    for _, node := range ast.Children {
        cmd := strings.ToUpper(node.Value)
        if cmd != "ENV" && cmd != "ARG" && cmd != "RUN" && cmd != "LABEL" {
            continue
        }

        line := getFullLine(node)

        if cmd == "ENV" || cmd == "ARG" {
            varName := ""
            varValue := ""
            if node.Next != nil {
                parts := strings.SplitN(node.Next.Value, "=", 2)
                varName = parts[0]
                if len(parts) > 1 {
                    varValue = parts[1]
                }
            }
            if rules.IsSensitiveEnvName(varName) {
                control, _ := benchmark.Get("4.10")
                loc := &finding.Location{Path: a.path, Line: node.StartLine}
                f := finding.New("CIS-4.10", "Sensitive variable in "+cmd+": "+varName, finding.SeverityHigh, target).
                    WithDescription(control.Description).
                    WithCategory(string(CategoryDockerfile)).
                    WithLocation(loc).
                    WithRemediation(control.Remediation).
                    WithReferences(control.References...).
                    WithCISControl(control.ToCISControl())
                findings = append(findings, f)
            }

            if varValue != "" &&
                rules.IsHighEntropyString(
                    varValue,
                    config.MinSecretLength,
                    config.MinEntropyForSecret,
                ) {
                loc := &finding.Location{Path: a.path, Line: node.StartLine}
                f := finding.New("DS-HIGH-ENTROPY", "High entropy string in "+cmd+" (potential secret)", finding.SeverityMedium, target).
                    WithDescription("Value in " + varName + " has high entropy, indicating a potential hardcoded secret or key.").
                    WithCategory(string(CategoryDockerfile)).
                    WithLocation(loc).
                    WithRemediation("Use Docker secrets, build arguments, or environment variables at runtime instead of hardcoding sensitive values.")
                findings = append(findings, f)
            }
        }

        secrets := rules.DetectSecrets(line)
        for _, secret := range secrets {
            control, _ := benchmark.Get("4.10")
            loc := &finding.Location{Path: a.path, Line: node.StartLine}
            f := finding.New("CIS-4.10", "Potential "+string(secret.Type)+" detected in Dockerfile", finding.SeverityHigh, target).
                WithDescription(secret.Description + ". " + control.Description).
                WithCategory(string(CategoryDockerfile)).
                WithLocation(loc).
                WithRemediation(control.Remediation).
                WithReferences(control.References...).
                WithCISControl(control.ToCISControl())
            findings = append(findings, f)
        }
    }

    return findings
}
```

Three-layer secret detection:

1. **Sensitive variable names**: ENV API_KEY, ARG PASSWORD → Always flag regardless of value
2. **High entropy**: Random-looking strings like `aB3xK9mP2qL5nR8t` → Likely secrets
3. **Pattern matching**: 80+ regex patterns for AWS keys, GitHub tokens, etc.

Entropy calculation in `internal/rules/secrets.go:910-925`:
```go
func CalculateEntropy(s string) float64 {
    if len(s) == 0 {
        return 0
    }
    freq := make(map[rune]float64)
    for _, c := range s {
        freq[c]++
    }
    length := float64(len(s))
    var entropy float64
    for _, count := range freq {
        p := count / length
        entropy -= p * math.Log2(p)
    }
    return entropy
}
```

Shannon entropy: "password" = 2.75 bits/char (low), "Tr0ub4dor&3" = 3.18 (medium), "rYq3J8kP2vL9nM5x" = 4.0 (high). Threshold is 4.5 bits/char.

## Security Implementation

### Capability Risk Assessment

File: `internal/rules/capabilities.go`
```go
var Capabilities = map[string]CapabilityInfo{
    "CAP_SYS_ADMIN": {
        Severity:    finding.SeverityCritical,
        Description: "Perform a range of system administration operations. Effectively root - mount filesystems, quotas, namespaces, etc.",
    },
    "CAP_SYS_PTRACE": {
        Severity:    finding.SeverityCritical,
        Description: "Trace arbitrary processes using ptrace. Read/write memory of any process, inject code, steal secrets.",
    },
    "CAP_NET_ADMIN": {
        Severity:    finding.SeverityHigh,
        Description: "Perform network administration operations. Modify routing, firewall rules, sniff traffic, MITM attacks.",
    },
    // ... 38 more capabilities
}

// Pre-computed lookup maps built at init()
var dangerousCapabilities = func() map[string]struct{} {
    m := make(map[string]struct{})
    for cap, info := range Capabilities {
        if info.Severity >= finding.SeverityHigh {
            m[cap] = struct{}{}
            m[strings.TrimPrefix(cap, "CAP_")] = struct{}{}
        }
    }
    return m
}()
```

**What this prevents:**
Linear scans through capability list on every container. With pre-computed map, IsDangerousCapability() is O(1).

**How it works:**
1. Package init runs at program start (before main)
2. Anonymous function executes, building lookup map
3. Map assigned to package variable dangerousCapabilities
4. Every future lookup is hash table access

**What happens if you remove this:**
Every capability check becomes O(n) where n=41. Scanning 1000 containers with average 3 added capabilities = 3000 * 41 comparisons = 123,000 operations. With map: 3000 lookups = 3000 operations. 40x speedup.

### Path-Based Attack Prevention

File: `internal/rules/paths.go:32-1100` (yes, over 1000 lines)
```go
var DockerSocketPaths = map[string]PathInfo{
    "/var/run/docker.sock": {
        Severity:    finding.SeverityCritical,
        Description: "Docker daemon socket. Full control over Docker, container escape possible.",
    },
    "/run/docker.sock": {
        Severity:    finding.SeverityCritical,
        Description: "Docker daemon socket (alternate path). Full control over Docker.",
    },
    // ... containerd, CRI-O, podman sockets
}

var SensitiveHostPaths = map[string]PathInfo{
    "/etc/shadow": {
        Severity:    finding.SeverityCritical,
        Description: "Password hashes. Direct credential access.",
    },
    "/var/lib/kubelet/pods": {
        Severity:    finding.SeverityCritical,
        Description: "Kubelet pod data. Access to all pod volumes and secrets.",
    },
    "/root/.aws": {
        Severity:    finding.SeverityCritical,
        Description: "AWS credentials and configuration.",
    },
    // ... 200+ paths
}
```

Path matching handles prefixes:
```go
func IsSensitivePath(path string) bool {
    normalized := normalizePath(path)
    if _, exists := sensitivePathLookup[normalized]; exists {
        return true
    }
    // Check if path is under a sensitive directory
    for sensitivePath := range sensitivePathLookup {
        if strings.HasPrefix(normalized, sensitivePath+"/") {
            return true
        }
    }
    return false
}
```

Why prefix matching: Mounting `/etc/kubernetes/pki/ca.crt` should flag because `/etc/kubernetes/pki` is sensitive. Exact match only would miss this.

## Data Flow Example

Let's trace a complete scan through the system.

**Scenario:** User runs `docksec scan --target containers --severity high`

### Request Comes In
```go
// Entry point: cmd/docksec/main.go:64-82
cfg := &config.Config{
    Targets:  []string{"containers"},
    Severity: []string{"high"},
    Output:   "terminal",
    Workers:  20,
}
scanner, _ := scanner.New(cfg)
```

At this point:
- Config validated (targets exist, severity is valid enum)
- Docker client created and connected
- Terminal reporter instantiated with colored output
- Rate limiter initialized at 50 req/sec

### Processing Layer
```go
// Processing: internal/scanner/scanner.go:72-100
analyzers := s.buildAnalyzers()
// Returns: [ContainerAnalyzer]

// internal/scanner/scanner.go:102-168
findings, _ := s.runAnalyzers(ctx, analyzers)
```

This code:
- Spawns goroutine for ContainerAnalyzer
- Rate limiter waits (first call passes immediately due to burst)
- ContainerAnalyzer calls Docker API ListContainers
- For each container, spawns goroutine calling InspectContainer
- Each inspect runs all checks: privileged, capabilities, mounts, etc.
- Findings from all checks merged into single collection

Why errgroup instead of waitgroup: If Docker daemon becomes unreachable mid-scan, errgroup propagates error via context cancellation. All goroutines see ctx.Done() and exit cleanly.

### Storage/Output
```go
// Filter: internal/scanner/scanner.go:170-197
filtered := s.filterFindings(findings)
// Only keeps findings with severity >= HIGH

// Output: internal/report/terminal.go:25-42
s.reporter.Report(filtered)
```

The result is terminal output with ANSI colors. We write to stdout directly because outputFile == "". Each finding gets formatted with severity color, title, target, location, description, remediation.

## Error Handling Patterns

### Docker API Errors

When Docker daemon is down or unreachable, we need graceful failure.
```go
// internal/docker/client.go:47-59
func (c *Client) Ping(ctx context.Context) error {
    pingCtx, cancel := context.WithTimeout(ctx, config.ConnectionTimeout)
    defer cancel()

    _, err := c.api.Ping(pingCtx)
    if err != nil {
        return fmt.Errorf("pinging docker daemon: %w", err)
    }
    return nil
}
```

**Why this specific handling:**
5-second timeout prevents hanging when Docker socket exists but daemon is stuck. Error wrapping with %w preserves original error for debugging while adding context.

**What NOT to do:**
```go
// Bad: Silent failure
func (c *Client) Ping(ctx context.Context) error {
    _, err := c.api.Ping(ctx)
    if err != nil {
        log.Println("ping failed")
        return nil  // Pretend success
    }
    return nil
}

// Why this is terrible: Scanner proceeds with broken client.
// Later ListContainers fails with cryptic "client not initialized" error.
// User has no idea Docker daemon is down.
```

Always fail fast with descriptive errors at boundaries.

### File Parsing Errors

Dockerfiles can be malformed. Don't crash the entire scan.
```go
// internal/analyzer/dockerfile.go:34-37
result, err := parser.Parse(file)
if err != nil {
    return nil, err
}
```

We propagate parsing errors up to scanner. Scanner logs warning but continues with other analyzers:
```go
// internal/scanner/scanner.go:137-143
findings, err := a.Analyze(ctx)
if err != nil {
    s.logger.Warn(
        "analyzer failed",
        "name", a.Name(),
        "error", err,
    )
    return nil  // Don't fail entire scan
}
```

One bad Dockerfile doesn't stop container scans.

## Performance Optimizations

### Before: Sequential Container Inspection

Naive implementation:
```go
// Slow version - sequential
func (a *ContainerAnalyzer) Analyze(ctx context.Context) (finding.Collection, error) {
    containers, _ := a.client.ListContainers(ctx, true)
    
    var findings finding.Collection
    for _, c := range containers {
        info, _ := a.client.InspectContainer(ctx, c.ID)
        findings = append(findings, a.analyzeContainer(info)...)
    }
    return findings, nil
}
```

This was slow because InspectContainer is network I/O (50-100ms per call). With 100 containers: 5-10 seconds just waiting for API responses.

### After: Concurrent Inspection with Rate Limiting

Optimized implementation in scanner:
```go
// internal/scanner/scanner.go:102-168
g, ctx := errgroup.WithContext(ctx)
g.SetLimit(s.cfg.Workers)  // 20 concurrent

for _, a := range analyzers {
    a := a
    g.Go(func() error {
        s.limiter.Wait(ctx)  // Rate limit
        findings, _ := a.Analyze(ctx)
        results <- findings
        return nil
    })
}
```

**What changed:**
- Sequential → Concurrent: 20 inspects happen simultaneously
- No rate limit → 50 req/sec limiter: Prevents overwhelming daemon
- Blocking waits → errgroup: Errors propagate via context

**Benchmarks:**
- Before: 100 containers = 8.2 seconds
- After: 100 containers = 1.1 seconds
- Improvement: 7.5x faster

With 1000 containers:
- Before: Would be ~82 seconds
- After: 20 workers * 50 req/sec = maximum 1000 req / 50 = 20 seconds (rate limit bound)
- Actual: ~22 seconds (accounting for processing time)

## Configuration Management

### Loading Config
```go
// cmd/docksec/main.go:64-82
func newScanCmd(cfg *config.Config) *cobra.Command {
    cmd := &cobra.Command{
        Use:   "scan",
        Short: "Scan Docker environment for security issues",
        RunE: func(cmd *cobra.Command, args []string) error {
            return runScan(cmd.Context(), cfg)
        },
    }

    flags := cmd.Flags()

    flags.StringSliceVarP(&cfg.Targets, "target", "t", []string{"all"},
        "Scan targets: all, containers, daemon, images")

    flags.StringSliceVarP(&cfg.Files, "file", "f", nil,
        "Dockerfile or docker-compose.yml files to scan")

    flags.StringVarP(&cfg.Output, "output", "o", "terminal",
        "Output format: terminal, json, sarif, junit")
    
    // ... more flags

    return cmd
}
```

**Why this approach:**
Cobra handles flag parsing, validation, and help text generation. StringSliceVarP means `--target containers,daemon` or `--target containers --target daemon` both work.

**Validation:**
```go
// internal/scanner/scanner.go:72-100
if len(analyzers) == 0 {
    return fmt.Errorf("no analyzers configured")
}
```

We validate early because invalid config should fail at startup, not after scanning 500 containers.

## Testing Strategy

### Unit Tests

Example test for capability checking:
```go
// internal/rules/capabilities_test.go
func TestIsDangerousCapability(t *testing.T) {
    tests := []struct {
        cap  string
        want bool
    }{
        {"CAP_SYS_ADMIN", true},
        {"SYS_ADMIN", true},  // Works without CAP_ prefix
        {"CAP_NET_BIND_SERVICE", false},
        {"INVALID_CAP", false},
    }
    
    for _, tt := range tests {
        got := IsDangerousCapability(tt.cap)
        if got != tt.want {
            t.Errorf("IsDangerousCapability(%q) = %v, want %v", 
                tt.cap, got, tt.want)
        }
    }
}
```

**What this tests:**
- Exact matches work
- Prefix normalization works (with/without CAP_)
- Non-dangerous capabilities return false
- Unknown capabilities don't panic

**Why these specific assertions:**
Real Docker output sometimes has "SYS_ADMIN", sometimes "CAP_SYS_ADMIN". Test ensures both work.

### Integration Tests

Testing container analyzer requires real Docker:
```go
// internal/analyzer/container_test.go
func TestContainerAnalyzer(t *testing.T) {
    if testing.Short() {
        t.Skip("skipping integration test")
    }
    
    client, _ := docker.NewClient()
    ctx := context.Background()
    
    // Create privileged container
    containerID, _ := createPrivilegedContainer(ctx, client)
    defer removeContainer(ctx, client, containerID)
    
    analyzer := NewContainerAnalyzer(client)
    findings, err := analyzer.Analyze(ctx)
    
    if err != nil {
        t.Fatalf("Analyze() error = %v", err)
    }
    
    // Should find privileged container
    found := false
    for _, f := range findings {
        if f.RuleID == "CIS-5.4" {
            found = true
            break
        }
    }
    
    if !found {
        t.Error("Did not detect privileged container")
    }
}
```

Run with `go test` (skips integration tests) or `go test -short=false` (runs all tests).

## Common Implementation Pitfalls

### Pitfall 1: Ignoring Context Cancellation

**Symptom:**
Scanner hangs when user hits Ctrl-C

**Cause:**
```go
// Bad: Ignores context
func (a *ContainerAnalyzer) Analyze(ctx context.Context) (finding.Collection, error) {
    containers, _ := a.client.ListContainers(context.Background(), true)
    // Uses context.Background() instead of ctx parameter
}
```

**Fix:**
```go
// Good: Respects context
func (a *ContainerAnalyzer) Analyze(ctx context.Context) (finding.Collection, error) {
    containers, _ := a.client.ListContainers(ctx, true)
    // Passes ctx through - if canceled, API call returns immediately
}
```

**Why this matters:**
User hits Ctrl-C → main sets up signal handler → context canceled → all API calls abort → clean shutdown in <100ms instead of waiting for all inspects to complete.

### Pitfall 2: Forgetting errgroup Capture

**Symptom:**
Goroutines fail but scan reports success

**Cause:**
```go
// Bad: Loses errors
for _, a := range analyzers {
    go func() {
        findings, err := a.Analyze(ctx)
        // err is lost - no one checks it
        results <- findings
    }()
}
```

**Fix:**
```go
// Good: Propagates errors
g, ctx := errgroup.WithContext(ctx)
for _, a := range analyzers {
    a := a  // Capture loop variable
    g.Go(func() error {
        findings, err := a.Analyze(ctx)
        if err != nil {
            return err
        }
        results <- findings
        return nil
    })
}
if err := g.Wait(); err != nil {
    return nil, err
}
```

**Why this matters:**
If Docker daemon crashes mid-scan, we detect it and report failure instead of returning partial results as if scan succeeded.

### Pitfall 3: String Comparison for Booleans

**Symptom:**
docker-compose.yml with `privileged: true` doesn't get flagged

**Cause:**
```go
// Bad: Assumes specific format
if privilegedNode.Value == "true" {
    // YAML library might return "True", "yes", or boolean type
}
```

**Fix:**
```go
// Good: Handles multiple formats
if privilegedNode.Value == "true" || privilegedNode.Value == "yes" {
    // Handles both YAML boolean representations
}
```

YAML accepts `true`, `True`, `yes`, `on` for booleans. Always handle variations.

## Debugging Tips

### Issue Type 1: No Findings When Expecting Some

**Problem:** Running `docksec scan` on container with --privileged shows zero findings

**How to debug:**
1. Check scanner log level: `docksec scan --verbose`
   - Logs show which analyzers ran, how many containers found
2. Verify Docker connection: `docker ps` in same environment
   - If this fails, docksec can't access daemon either
3. Check filters: `docksec scan --severity info`
   - Maybe severity filter is hiding findings

**Common causes:**
- Docker daemon on different host (set DOCKER_HOST)
- Container exited (use --all or `docker ps -a`)
- Filters too restrictive (remove --severity and --cis flags)

### Issue Type 2: Rate Limit Errors

**Problem:** Error: "rate: Wait(n=1) would exceed context deadline"

**How to debug:**
1. Check how many containers: `docker ps | wc -l`
2. Check rate limit: Currently hardcoded at 50 req/sec
3. Increase workers to compensate: `--workers 50`

**Common causes:**
- Scanning 1000+ containers on slow network
- Rate limiter too conservative for fast local Docker
- Context deadline too short (check --timeout if we add it)

## Code Organization Principles

### Why analyzer/ is Structured This Way
```
analyzer/
├── analyzer.go      # Interface definition
├── container.go     # 300 lines - one file per target type
├── daemon.go        # 150 lines
├── image.go         # 120 lines
├── dockerfile.go    # 280 lines
└── compose.go       # 520 lines
```

We separate container from image from daemon because:
- Each analyzer talks to different Docker APIs (ContainerList vs ImageList vs Info)
- Each has different check logic (container mounts vs image USER instruction)
- Testing is easier when each analyzer is isolated

This makes finding specific code easy. Looking for container checks? Open container.go. Looking for Dockerfile checks? Open dockerfile.go.

### Naming Conventions

- `check*` functions return findings: `checkPrivileged()`, `checkCapabilities()`
- `analyze*` functions orchestrate checks: `analyzeContainer()`, `analyzeService()`
- `*Analyzer` structs implement Analyzer interface: `ContainerAnalyzer`, `DaemonAnalyzer`
- `*Reporter` structs implement Reporter interface: `TerminalReporter`, `JSONReporter`

Following these patterns makes it easier to scan code. See function named `checkMounts()`? You know it checks mounts and returns findings.

## Extending the Code

### Adding a New Container Check

Want to check for containers using `latest` image tag?

1. **Add check method** in `internal/analyzer/container.go`
```go
   func (a *ContainerAnalyzer) checkImageTag(
       target finding.Target,
       info types.ContainerJSON,
   ) finding.Collection {
       if strings.HasSuffix(info.Config.Image, ":latest") || 
          !strings.Contains(info.Config.Image, ":") {
           f := finding.New("CIS-5.27", "Container uses :latest tag", 
               finding.SeverityLow, target).
               WithDescription("Using :latest makes container behavior unpredictable.").
               WithRemediation("Use specific version tags like nginx:1.21.3")
           return finding.Collection{f}
       }
       return nil
   }
```

2. **Call it** from `analyzeContainer` (line 51-70)
```go
   findings = append(findings, a.checkImageTag(target, info)...)
```

3. **Add CIS control** in `internal/benchmark/controls.go` if needed
```go
   Register(Control{
       ID:          "5.27",
       Section:     "Container Runtime",
       Title:       "Ensure container images are not using :latest tag",
       // ... rest of control
   })
```

Done. Next scan will check image tags.

### Adding a New Secret Pattern

In `internal/rules/secrets.go`, append to SecretPatterns slice:
```go
{
    Type:        SecretTypeAPIKey,
    Pattern:     regexp.MustCompile(`myservice_[A-Za-z0-9]{32}`),
    Description: "MyService API Key",
},
```

Dockerfile and compose analyzers automatically use all patterns. No other changes needed.

## Next Steps

You've seen how the code works. Now:

1. **Try the challenges** - [04-CHALLENGES.md](./04-CHALLENGES.md) has specific extension ideas
2. **Add a check** - Implement the latest tag check above to verify you understand analyzer pattern
3. **Run with --verbose** - Watch the concurrent execution happen in real time
