# DNS Lookup Tool - Project Overview

## What This Project Does

This is a professional DNS reconnaissance tool built as a command-line application. It performs DNS queries, reverse lookups, resolution tracing, and WHOIS information gathering. The tool is designed for network analysis, security research, and learning how DNS infrastructure works at a technical level.

Unlike simple `dig` or `nslookup` wrappers, this project implements concurrent async DNS queries, resolution path tracing from root servers, and structured output formatting suitable for both human analysis and automated processing.

## Core Capabilities

**DNS Record Queries** (`dnslookup/cli.py:112-167`)
- Query multiple record types simultaneously (A, AAAA, MX, NS, TXT, CNAME, SOA)
- Custom DNS server selection
- Configurable timeouts
- JSON output for parsing

**Reverse DNS Lookups** (`dnslookup/cli.py:170-216`)
- IPv4 and IPv6 PTR record resolution
- Useful for identifying server ownership and detecting hosting patterns

**DNS Trace** (`dnslookup/cli.py:219-263`)
- Traces complete resolution path from root servers through TLD to authoritative nameservers
- Visualizes DNS delegation hierarchy
- Shows which servers are queried at each step

**Batch Operations** (`dnslookup/cli.py:266-350`)
- Process hundreds of domains from a file
- Concurrent async queries for speed
- Results export to JSON

**WHOIS Lookups** (`dnslookup/cli.py:353-393`)
- Domain registration details
- Registrar information, creation dates, expiration dates
- Name server information

## Why This Matters for Security

DNS is a fundamental attack surface. This tool teaches:

1. **Reconnaissance Techniques**: How attackers enumerate infrastructure
2. **DNS Architecture**: Understanding delegation makes spoofing and hijacking clearer
3. **Information Leakage**: What data DNS exposes about your infrastructure
4. **Attack Detection**: Recognizing unusual DNS patterns

Real incidents this knowledge applies to:
- **Dyn DDoS Attack (2016)**: Massive DNS infrastructure disruption affected Twitter, Netflix, Reddit
- **Sea Turtle Campaign (2019)**: Nation-state DNS hijacking targeting government agencies (MITRE ATT&CK: T1584.002)
- **DNSpionage (2018)**: DNS hijacking for credential harvesting

## Technical Architecture
```
User Command
    ↓
cli.py (Typer interface)
    ↓
resolver.py (dnspython async wrapper)
    ↓
DNS Protocol Operations
    ↓
output.py (Rich formatting)
    ↓
Terminal Display
```

The architecture separates concerns cleanly:
- **CLI layer**: User interaction, argument parsing (`cli.py`)
- **Resolution layer**: DNS protocol operations (`resolver.py`)
- **Presentation layer**: Output formatting (`output.py`)

## Learning Path

This project teaches:
1. **DNS Protocol Mechanics**: How queries actually work at the packet level
2. **Async Python**: Using `asyncio` for concurrent network operations
3. **CLI Design**: Building professional command-line tools with Typer
4. **Error Handling**: Network timeouts, NXDOMAIN, SERVFAIL responses
5. **Data Structures**: Modeling DNS records cleanly
6. **Security Mindset**: Thinking like both defender and attacker

## Quick Start Examples
```bash
# Basic query - all record types
dnslookup query example.com

# Specific records with custom DNS server
dnslookup query example.com --type A,MX --server 8.8.8.8

# Trace resolution path (shows DNS hierarchy)
dnslookup trace example.com

# Reverse lookup to find hostname
dnslookup reverse 8.8.8.8

# Batch reconnaissance
echo "example.com" > domains.txt
echo "example.org" >> domains.txt
dnslookup batch domains.txt --output results.json
```

## Key Files to Understand

| File | Purpose | Lines of Code |
|------|---------|---------------|
| `resolver.py` | Core DNS logic | ~400 |
| `cli.py` | Command interface | ~400 |
| `output.py` | Terminal formatting | ~400 |
| `whois_lookup.py` | WHOIS operations | ~200 |

## Security Features

- **No caching**: Every query is fresh (prevents stale data)
- **Custom nameserver support**: Test against specific DNS servers
- **Timeout controls**: Prevents hanging on unresponsive servers
- **Error transparency**: Shows exactly what failed and why

## What You'll Build On

After mastering this project, you'll be ready for:
- DNS tunnel detection systems
- Custom DNS servers with security monitoring
- Automated subdomain enumeration tools
- DNS-based threat intelligence gathering

## Real World Applications

This exact functionality is used in:
- **Penetration Testing**: Initial reconnaissance phase
- **Incident Response**: Investigating suspicious domains
- **Threat Hunting**: Tracking C2 infrastructure
- **Infrastructure Monitoring**: Validating DNS configurations
- **Security Research**: Analyzing DNS patterns

## Attack Vectors This Tool Helps Understand

1. **DNS Reconnaissance** (MITRE T1590.002): Information gathering attackers perform
2. **DNS Tunneling**: Exfiltrating data through DNS queries
3. **DNS Cache Poisoning**: How spoofed responses could redirect traffic
4. **Subdomain Enumeration**: Finding hidden infrastructure
5. **DNS Amplification**: How DNS can be weaponized for DDoS

Next, dive into `01-CONCEPTS.md` to understand the DNS protocol fundamentals this tool leverages.
