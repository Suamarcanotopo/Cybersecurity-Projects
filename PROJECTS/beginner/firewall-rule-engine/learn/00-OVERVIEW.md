<!-- © AngelaMos | 2026 | 00-OVERVIEW.md -->

# Firewall Rule Engine

## What This Is

A CLI tool called `fwrule` that parses iptables and nftables rulesets, detects conflicts between rules (shadowing, contradictions, duplicates), suggests performance and security optimizations, and generates hardened rulesets from scratch. It reads raw ruleset files, runs pairwise analysis across every rule in each chain, and outputs findings with severity ratings and fix suggestions. Written in V.

## Why This Matters

Firewall misconfigurations are behind a significant percentage of cloud breaches, and the problem is almost always the same: someone wrote rules that look correct on paper but interact in ways they did not expect.

The Capital One breach in 2019 (CVE-2019-5418) happened because a WAF was misconfigured, allowing an attacker to perform SSRF against the EC2 metadata service and exfiltrate 100 million customer records from S3. The firewall rules were too permissive on the WAF role, and nobody caught it. The company paid $80 million in fines and $190 million in settlements.

AWS publishes that security group misconfigurations are one of the top causes of S3 bucket exposures. The Imperva breach in 2019 traced back to an AWS API key exposed through a misconfigured internal instance that should have been firewalled off. The National Security Agency published a cybersecurity advisory (U/OO/179891-20) specifically about misconfigured IPsec VPN firewall rules allowing adversary lateral movement.

Three concrete scenarios where this tool applies:

1. **Shadowed rules**: You add `-A INPUT -p tcp --dport 80 -j ACCEPT` early in your chain, then later add a more specific rule to block a known malicious subnet on port 80. The specific rule never fires because the broad ACCEPT catches everything first. This is the single most common firewall misconfiguration.

2. **Missing connection tracking**: A ruleset allows SSH on port 22 but has no `ESTABLISHED,RELATED` rule near the top. Every packet in every existing TCP session has to traverse the entire chain instead of matching immediately. On a busy server, this means thousands of unnecessary rule evaluations per second.

3. **No rate limiting on SSH**: Port 22 is open with a plain ACCEPT. An attacker runs hydra or medusa against it with thousands of password attempts per minute. A rate limit of 3/minute with burst 5 would have made brute force impractical.

## What You'll Learn

**Security Concepts:**
- How netfilter processes packets through tables and chains (filter, nat, mangle, raw)
- The difference between iptables (legacy userspace tool) and nftables (its replacement since Linux 3.13)
- Rule evaluation order and why position in the chain determines behavior
- Connection tracking (conntrack) and stateful firewalling with NEW, ESTABLISHED, RELATED, INVALID states
- Default-deny policies vs default-accept, and why the distinction matters

**Technical Skills:**
- The V programming language (syntax, modules, option types, tagged unions, flag enums)
- Parsing domain-specific languages (tokenizing iptables flags, parsing nftables block structure)
- Pairwise conflict detection: checking every rule pair for superset/subset relationships on IPs, ports, and protocols
- CIDR math: converting IP addresses to 32-bit integers and comparing network prefixes with bit shifts

**Tools:**
- `v fmt` for code formatting (V's built-in formatter, similar to gofmt)
- `v test` for running the test suite
- `just` command runner for build, test, format, and smoke test recipes

## Prerequisites

### Required

- Basic networking knowledge: TCP/IP, what ports are, what a firewall does
- Command line familiarity: navigating directories, running commands, reading terminal output
- Any programming language experience: if you can read C, Go, or Python, V will make sense immediately

### Tools

- **V 0.5+** (the install script handles this automatically if you do not have it)
- **just** command runner (optional but makes everything easier)

### Helpful But Not Required

- Linux system administration experience
- Hands-on work with iptables or nftables
- Familiarity with CIDR notation and subnet masks

## Quick Start

```bash
git clone https://github.com/CarterPerez-dev/Cybersecurity-Projects.git
cd PROJECTS/beginner/firewall-rule-engine

./install.sh

fwrule analyze testdata/iptables_conflicts.rules
```

The `analyze` command parses the ruleset, detects that rule 8 (ACCEPT tcp/22 from 10.0.0.0/8) is shadowed by rule 7 (ACCEPT tcp/22 from anywhere), finds that rules 9 and 10 are duplicates (both ACCEPT tcp/80), and flags the contradiction between rule 11 (ACCEPT tcp/443 from 192.168.1.0/24) and rule 12 (DROP tcp/443 from 192.168.0.0/16 which contains 192.168.1.0/24).

Try a few more commands:

```bash
fwrule load testdata/nftables_basic.rules

fwrule harden -s ssh,http,https -f nftables

fwrule export testdata/iptables_basic.rules -f nftables

fwrule diff testdata/iptables_basic.rules testdata/nftables_basic.rules
```

## Project Structure

```
firewall-rule-engine/
├── src/
│   ├── main.v                  CLI entry point, subcommand dispatch
│   ├── config/
│   │   └── config.v            Constants: ports, CIDR ranges, rate limits, service map
│   ├── models/
│   │   └── models.v            Core types: Rule, Ruleset, Finding, NetworkAddr, PortSpec
│   ├── parser/
│   │   ├── common.v            Shared parsing: protocols, actions, CIDR, port specs
│   │   ├── iptables.v          iptables-save format tokenizer and rule parser
│   │   ├── nftables.v          nftables block-structured format parser
│   │   └── parser_test.v       Parser test suite
│   ├── analyzer/
│   │   ├── conflict.v          Pairwise analysis: shadows, contradictions, duplicates
│   │   ├── optimizer.v         Optimization: port merging, reordering, missing conntrack
│   │   └── analyzer_test.v     Analyzer test suite
│   ├── generator/
│   │   ├── generator.v         Hardened ruleset generation, format conversion
│   │   └── generator_test.v    Generator test suite
│   └── display/
│       └── display.v           Terminal output: tables, colored findings, diffs
├── testdata/
│   ├── iptables_basic.rules    Clean iptables ruleset
│   ├── iptables_complex.rules  Larger iptables ruleset with NAT and multiple tables
│   ├── iptables_conflicts.rules Intentionally broken rules for testing conflict detection
│   ├── nftables_basic.rules    Clean nftables ruleset
│   ├── nftables_complex.rules  Larger nftables ruleset
│   └── nftables_conflicts.rules Intentionally broken nftables rules
├── learn/                      You are here
├── install.sh                  One-command setup (installs V if needed, builds, installs)
├── Justfile                    Build/test/format/smoke-test recipes
├── v.mod                       V module metadata
└── LICENSE
```

## Next Steps

1. [01-CONCEPTS.md](./01-CONCEPTS.md) - Netfilter architecture, iptables vs nftables, chain evaluation, connection tracking
2. [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) - How the parser, analyzer, and generator modules interact, data flow from raw text to findings
3. [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) - Code walkthrough: tokenization, CIDR math, pairwise conflict detection, hardened ruleset generation
4. [04-CHALLENGES.md](./04-CHALLENGES.md) - Extensions: IPv6 support, live system import, firewalld/ufw parsing, rule visualization

## Common Issues

**`v: command not found` after cloning**

Run `./install.sh`. It clones the V compiler from source, builds it, and adds it to your PATH. If you already ran it and still get the error, restart your shell or run `source ~/.zshrc` (or `~/.bashrc`).

**Tests fail with import errors**

Run tests from the project root, not from inside `src/`:
```bash
v test src/
```
V resolves module imports relative to the project root. Running `v test` from inside a subdirectory breaks the import paths.

**`v fmt` reports formatting errors**

Run the formatter in write mode to fix them automatically:
```bash
v fmt -w src/
```
Or use `just fmt` which does the same thing. To check without modifying files, use `just fmt-check`.

**Binary not found after install**

The install script puts the binary at `~/.local/bin/fwrule`. If that directory is not in your PATH, either add it or run the binary directly:
```bash
~/.local/bin/fwrule analyze testdata/iptables_conflicts.rules
```
