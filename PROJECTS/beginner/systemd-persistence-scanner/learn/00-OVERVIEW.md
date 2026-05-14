# Sentinel - Systemd Persistence Scanner

## What This Is

A single-binary CLI tool that scans a Linux system for persistence mechanisms across 17 scanner modules: systemd units, cron jobs, shell profiles, SSH configuration, LD_PRELOAD hijacking, kernel modules, udev rules, init.d scripts, XDG autostart, at jobs, MOTD scripts, PAM configuration, sshrc login scripts, logrotate hooks, systemd generators, bash completion scripts, and network interface hooks. Every finding is tagged with a MITRE ATT&CK technique ID and a severity from info to critical.

## Why This Matters

Persistence is how attackers survive reboots. After initial access, the first thing a competent adversary does is install a mechanism that brings them back. Linux has dozens of locations where code can be triggered automatically: boot services, login events, hardware changes, scheduled tasks, shell initialization, module loads, device events.

In the 2020 SolarWinds compromise, attackers modified systemd services on Linux build servers to maintain access across updates. In the 2021 Codecov incident, attackers injected curl commands into shell profile scripts on CI/CD runners. The 2022 Orbit Linux malware used LD_PRELOAD to hook libc functions and hide from every detection tool on the system.

**Real world scenarios where this applies:**
- Incident response triage: drop the binary on a compromised host and get a full persistence inventory in seconds
- Hardening audits: baseline a clean server, then diff after deployments to catch unintended persistence
- Threat hunting: sweep a fleet for known persistence patterns like reverse shells in cron or SUID manipulation in profile scripts

## What You'll Learn

This project teaches you how Linux persistence works at every level of the boot and login sequence. By building it yourself, you'll understand:

**Security Concepts:**
- Linux persistence taxonomy: the 17 categories of locations where code runs automatically
- MITRE ATT&CK Persistence tactic (TA0003): mapping real techniques to detection logic
- Heuristic detection: pattern matching for reverse shells, download-and-execute chains, encoded payloads, alias hijacking, and privilege escalation primitives
- Baseline diffing: establishing known-good state and detecting drift

**Technical Skills:**
- Go module layout with internal packages, shared types, and a CLI layer
- Scanner registry pattern with init-time registration and parallel execution
- Concurrent scanning with errgroup and mutex-protected result collection
- Compiled regex pattern engine with severity-ranked matching
- Cobra CLI framework with subcommands, persistent flags, and structured output

**Tools and Techniques:**
- golangci-lint v2 with gci, gofumpt, golines formatters for consistent code style
- `go install` for single-command binary distribution
- just command runner for development workflows
- JSON output for SIEM ingestion and pipeline integration

## Prerequisites

**Required knowledge:**
- Go basics: structs, interfaces, goroutines, channels, error handling
- Linux filesystem layout: /etc, /home, /var/spool, /lib, /run
- Basic understanding of what services, cron, and shell profiles do

**Tools you'll need:**
- Go 1.25+ (the go.mod specifies this minimum)
- golangci-lint v2 (for linting)
- just (optional, for running development commands)

**Helpful but not required:**
- Familiarity with systemd unit file syntax
- Experience with regex patterns
- Understanding of MITRE ATT&CK framework

## Quick Start

```bash
cd PROJECTS/beginner/systemd-persistence-scanner

./install.sh

./bin/sentinel scan
```

Or install globally:

```bash
go install github.com/CarterPerez-dev/sentinel/cmd/sentinel@latest
sentinel scan
```

Expected output: The tool prints the SENTINEL banner in alternating cyan/red, scans all 17 persistence categories in parallel, and displays any findings grouped by severity with color-coded labels, file paths, evidence snippets, and MITRE technique IDs. On a clean system you'll see mostly info-level findings for legitimate services and cron jobs.

## Project Structure

```
systemd-persistence-scanner/
├── cmd/sentinel/          # Entry point (main.go)
├── pkg/types/             # Shared domain types (Finding, Severity, Scanner interface)
├── internal/
│   ├── cli/               # Cobra commands (scan, baseline save/diff)
│   ├── scanner/           # 17 scanner modules + registry + pattern engine + helpers
│   ├── baseline/          # JSON snapshot save/load/diff
│   ├── config/            # Ignore-list filtering
│   ├── report/            # Terminal and JSON output formatters
│   └── ui/                # Color, spinner, banner, symbols
├── testdata/              # Fixture files for each scanner's tests
├── Justfile               # Development command runner
└── install.sh             # Zero-friction setup script
```

## Next Steps

1. **Understand the concepts** - Read [01-CONCEPTS.md](./01-CONCEPTS.md) to learn Linux persistence techniques and MITRE ATT&CK mapping
2. **Study the architecture** - Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) to see the scanner registry, parallel execution, and data flow
3. **Walk through the code** - Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for the pattern engine, scanner modules, and baseline diffing
4. **Extend the project** - Read [04-CHALLENGES.md](./04-CHALLENGES.md) for ideas like adding new scanners and YARA integration

## Common Issues

**"go: go.mod requires go >= 1.25"**
You need Go 1.25 or later. Download from https://go.dev/dl/

**No findings on a minimal container or VM**
That's expected. Clean systems have few persistence mechanisms. Try `sentinel scan --root testdata` to scan the bundled test fixtures and see the detection engine in action.

**Permission denied on /var/spool/cron or /etc/shadow**
Some directories require root access. Run `sudo sentinel scan` for a full system scan, or use `--root` to scan a mounted filesystem image without elevated privileges.

## Related Projects

If you found this interesting, check out:
- [Linux CIS Hardening Auditor](../../linux-cis-hardening-auditor) - Compliance checking against CIS benchmarks
- [Simple Vulnerability Scanner](../../simple-vulnerability-scanner) - CVE-based dependency scanning
- [Linux eBPF Security Tracer](../../linux-ebpf-security-tracer) - Real-time syscall monitoring with eBPF
