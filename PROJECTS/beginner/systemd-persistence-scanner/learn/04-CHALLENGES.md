# Extension Challenges

Ideas for extending this project, ordered by difficulty. Each one teaches a different skill. Don't feel like you need to do them in order.

## Easy Challenges

### 1. Add a Docker Persistence Scanner

Docker containers can be configured to restart automatically, and Docker volumes can mount host paths that persist across container restarts. Attackers use `--restart=always` containers and bind mounts to /etc/cron.d as persistence mechanisms.

**What to build:** A scanner that checks /etc/docker/daemon.json for insecure configurations (like `--insecure-registry`), enumerates Dockerfiles in common locations, and checks for docker.service overrides.

**What you'll learn:** How container orchestration creates new persistence surfaces that traditional scanners miss.

**Hints:**
- Start with checking if /etc/docker/daemon.json exists and parsing it for suspicious settings
- Check /etc/systemd/system/docker.service.d/ for drop-in overrides
- MITRE technique: T1610 (Deploy Container)

**Test it works:** Create testdata/docker/daemon.json with an insecure configuration and verify the scanner flags it.

### 2. Add Cloud-Init Persistence Scanner

Cloud-init runs on first boot (and optionally on every boot) in cloud VMs. User data scripts in /var/lib/cloud/instance/scripts/ and cloud-config in /var/lib/cloud/instance/user-data.txt can contain arbitrary commands.

**What to build:** Scan cloud-init locations for user-data scripts containing network tools, encoded payloads, or download-and-execute chains.

**What you'll learn:** How cloud initialization creates a persistence vector unique to cloud environments.

**Hints:**
- Key directories: /var/lib/cloud/instance/, /var/lib/cloud/scripts/per-boot/
- Use ScanFileForPatterns() since cloud-init scripts are plain shell
- MITRE technique: T1078.004 (Valid Accounts: Cloud Accounts)

### 3. Add Severity-Based Exit Codes

CI/CD pipelines need a way to fail builds when critical findings exist. Right now sentinel always exits 0.

**What to build:** Exit code 1 when findings at or above a specified severity are found. Add a `--fail-on` flag that sets the threshold.

**What you'll learn:** How security tools integrate into automated pipelines. Most commercial scanners use exit codes for policy enforcement.

**Hints:**
- Add `--fail-on` as a persistent flag alongside `--min-severity`
- After printing output, check if any findings meet the threshold
- Exit code 0 = clean, 1 = findings above threshold, 2 = scan error

**Test it works:**
```bash
sentinel scan --root testdata --fail-on critical; echo $?
```

## Intermediate Challenges

### 4. Add Glob Pattern Matching to Ignore Rules

Currently ignore rules match exact paths. Real-world usage needs glob patterns like `/etc/cron.d/*` or `/home/*/.*rc`.

**What to build:** Extend the ignore-list matcher to support shell glob patterns using `filepath.Match()`.

**What you'll learn:** How to balance expressiveness with safety in configuration formats. Glob patterns are more useful than exact matches but introduce the risk of over-suppression.

**Implementation approach:**

1. Modify `matchesFinding` in config.go to check if the path field contains glob characters (*, ?, [)
2. If it does, use `filepath.Match(rule.Path, finding.Path)` instead of exact comparison
3. Add test cases for wildcard and question mark patterns
4. Document the supported glob syntax in the ignore file format

**Hints:**
- `filepath.Match()` is safe (no `**` recursion, no regex injection)
- Consider adding a `pattern:` field separate from `path:` if you want to preserve backward compatibility

### 5. Add HTML Report Output

JSON is great for machines. Terminal output is great for quick checks. But incident response reports need to be shared with management and legal teams who don't read terminals.

**What to build:** An `--html` flag that generates a self-contained HTML report with findings grouped by severity, sortable tables, and expandable evidence sections.

**What you'll learn:** Report generation, Go's html/template package, and how to produce self-contained (no external CSS/JS dependencies) HTML documents.

**Implementation approach:**

1. Create internal/report/html.go with an HTML template
2. Embed the CSS inline in a `<style>` block
3. Use severity colors from the terminal renderer as hex codes
4. Include the scan metadata (hostname, timestamp, duration) in a header

**Hints:**
- Use `html/template` (not `text/template`) to auto-escape evidence strings that might contain HTML
- Embed the template with `//go:embed` for a single-binary deployment
- Consider a summary chart using pure CSS bar widths (no JavaScript needed)

### 6. Add File Hash Collection

When a finding references a suspicious file, incident responders need to verify it hasn't changed. Collecting SHA256 hashes at scan time provides a tamper-evident record.

**What to build:** Add a `Hash` field to types.Finding. Compute SHA256 for every file that produces a finding above info severity.

**What you'll learn:** How forensic tools chain evidence with cryptographic hashes, and the performance implications of hashing files during a scan.

**Hints:**
- Use `crypto/sha256` and `io.Copy()` for streaming hash computation
- Only hash regular files, not directories or symlinks
- Add the hash to both terminal and JSON output
- Consider a `--no-hash` flag for performance-sensitive environments

## Advanced Challenges

### 7. Add YARA Rule Integration

YARA is the industry standard for pattern matching in files. Security teams write YARA rules to detect specific malware families, threat actor tooling, and indicators of compromise. Integrating YARA would let sentinel use the same rules as commercial EDR products.

**What to build:** A `--yara-rules` flag that loads a YARA rules file and applies it to every file that scanners examine. YARA matches produce findings with the rule name as the title.

**What you'll learn:** CGo integration (YARA's Go bindings use CGo), rule-based detection engines, and how the commercial security industry approaches pattern matching.

**Architecture changes needed:**

```
Scanner
   │
   ├── MatchLine() (existing regex engine)
   │
   └── MatchYARA() (new YARA engine)
          │
          ▼
      yara.Rules compiled from user-provided .yar file
```

**Implementation steps:**

1. Add github.com/hillu/go-yara/v4 dependency
2. Create internal/scanner/yara.go with rule compilation and matching
3. Modify ScanFileForPatterns to optionally apply YARA rules
4. Map YARA rule metadata (severity, mitre) to Finding fields

**Gotchas:**
- CGo means cross-compilation becomes harder and builds are slower
- YARA rule compilation is expensive; compile once and reuse the scanner object
- Consider making YARA optional (build tag) to keep the zero-dependency default

### 8. Add Remote Scanning via SSH

Right now sentinel must be deployed on the target host. For fleet-wide scanning, SSH-based remote execution would let a single workstation scan hundreds of servers.

**What to build:** A `sentinel remote scan --host user@server` command that SSH into the target, copies the binary, runs it, and streams JSON results back.

**What you'll learn:** SSH protocol integration in Go, binary self-deployment, and the architectural difference between agent-based and agentless scanning.

**Implementation steps:**

1. Use golang.org/x/crypto/ssh for the SSH connection
2. Use SFTP to copy the sentinel binary to the remote host
3. Execute `sentinel scan --json` on the remote host
4. Parse the JSON output locally and render it
5. Clean up the remote binary after scanning

**Gotchas:**
- The binary must be compiled for the target architecture (GOOS/GOARCH)
- SSH key authentication should be preferred over password
- Consider a `--parallel` flag for scanning multiple hosts concurrently

### 9. Add Timeline Analysis

Instead of a point-in-time scan, build a timeline that shows when each persistence mechanism was installed by correlating file modification times, cron job schedules, and systemd unit timestamps.

**What to build:** A `sentinel timeline` command that produces a chronological view of persistence installations, helping incident responders reconstruct the attack sequence.

**What you'll learn:** Forensic timeline reconstruction, filesystem metadata analysis, and how time-based correlation reveals attack patterns that individual findings miss.

**Implementation approach:**

1. Extend Finding with a `Timestamp` field (file mtime)
2. Sort findings by timestamp across all scanners
3. Render as a chronological list with time deltas between events
4. Highlight clusters of activity (multiple changes within minutes suggest automated installation)

## Security Challenges

### 10. Add Anti-Evasion Checks

Attackers know about persistence scanners. They use techniques to evade detection:

- Unicode homoglyphs in filenames (using Cyrillic "е" instead of Latin "e")
- Null bytes in file content to break line-based parsing
- Extremely long lines to exhaust regex engines (ReDoS)
- Symlinks pointing outside the scan root
- Hidden files (dotfiles) in unexpected locations

**What to build:** Harden the scanner against these evasion techniques.

**What you'll learn:** The adversarial mindset. Building a security tool that can itself be attacked teaches you to think like the attacker.

**Specific checks to add:**
- Detect non-ASCII characters in filenames and flag them
- Follow symlinks cautiously (resolve and verify they stay within the scan root)
- Set a maximum line length for pattern matching
- Scan dotfiles explicitly (some scanners skip them)

### 11. Add CIS Benchmark Cross-Reference

Map sentinel findings to CIS Benchmark controls for the target distribution. A finding like "World-writable unit file" maps to CIS control 6.1.x (System File Permissions).

**What to build:** A `--cis` flag that adds CIS control IDs alongside MITRE technique IDs in the output.

**What you'll learn:** How compliance frameworks overlap with threat detection, and why organizations need both perspectives.

## Performance Challenges

### 12. Benchmark and Optimize Pattern Matching

The current pattern engine runs all 16 regexes against every line. On systems with thousands of configuration files, this could become a bottleneck.

**What to build:** Add benchmarks using `testing.B`, profile the pattern engine, and optimize hot paths.

**What you'll learn:** Go profiling with pprof, regex performance characteristics, and when optimization matters versus when it doesn't.

**Approach:**
- Write benchmarks for MatchLine with various line types (matching, non-matching, long lines)
- Profile with `go test -bench . -cpuprofile cpu.prof`
- Consider: early exit on first match when severity ordering is irrelevant, pre-filtering with strings.Contains before regex, Aho-Corasick for literal patterns

**Target:** Scan 10,000 files in under 1 second on a single core.

## Contribution Ideas

Finished a challenge? Share it back:

1. Fork the [sentinel repo](https://github.com/CarterPerez-dev/sentinel)
2. Implement your extension in a new branch
3. Add tests and testdata fixtures
4. Submit a PR with your implementation and a description of what it detects

## Challenge Yourself Further

### Build Something New

Use the concepts you learned here to build:
- A Windows persistence scanner (Run keys, scheduled tasks, WMI subscriptions, services)
- A macOS persistence scanner (LaunchAgents, LaunchDaemons, login items, cron)
- A Kubernetes persistence scanner (DaemonSets, CronJobs, mutating webhooks, static pods)

### Study Real Implementations

Compare sentinel's approach to production tools:
- [Velociraptor](https://github.com/Velocidex/velociraptor) - Uses VQL queries to hunt for persistence across endpoints
- [PEASS-ng/linPEAS](https://github.com/carlospolop/PEASS-ng) - Bash-based Linux privilege escalation and persistence enumeration
- [Autoruns for Linux](https://github.com/microsoft/Autoruns-for-Linux) - Microsoft's take on Linux persistence enumeration

Read their code, understand their detection rules, and compare coverage. What do they catch that sentinel doesn't? What does sentinel catch that they miss?
