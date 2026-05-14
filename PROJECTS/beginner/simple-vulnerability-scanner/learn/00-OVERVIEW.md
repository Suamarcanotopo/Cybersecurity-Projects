# angela - Python Dependency Security Scanner

## What This Is

angela is a CLI tool that scans Python projects for outdated dependencies and known security vulnerabilities. It reads your `pyproject.toml` or `requirements.txt`, checks PyPI for the latest versions, queries OSV.dev for CVEs, and updates your dependency file while preserving all your comments and formatting.

## Why This Matters

In December 2022, the PyTorch package on PyPI was compromised with a malicious dependency (`torchtriton`) that exfiltrated environment variables and AWS credentials. Users who ran `pip install torch` during a specific time window unknowingly installed malware. This happened because PyPI allows anyone to upload packages, and dependency confusion attacks are trivial to execute.

The 2021 ua-parser-js incident showed another vector: a legitimate package with 8 million weekly downloads was hijacked when the maintainer's npm credentials were stolen. The attacker pushed versions 0.7.29, 0.8.0, and 1.0.0 containing cryptocurrency miners and password stealers. Over 1,000 projects were infected before npm took it down.

**Real world scenarios where this applies:**
- Your project depends on `requests==2.28.0`, but 2.28.1 fixes CVE-2023-32681 (a header injection vulnerability that allows attackers to inject arbitrary headers and cookies)
- You're running `django==3.2.0`, unaware that versions before 3.2.19 are vulnerable to CVE-2023-31047, allowing SQL injection via crafted filenames
- A transitive dependency three layers deep has a critical RCE, but you never even look at `pip list` output

## What You'll Learn

This project teaches you how dependency resolution and vulnerability scanning work at the protocol level. By building it yourself, you'll understand:

**Security Concepts:**
- Supply chain attacks via dependency confusion, typosquatting, and package takeover. You'll learn how attackers exploit the fact that `pip` will install any package with the right name, regardless of who published it.
- CVE databases and how OSV.dev aggregates vulnerability data from GitHub Security Advisories, PyPA, and the National Vulnerability Database into a queryable API
- Version resolution strategies including PEP 440 parsing, which handles epochs, pre-releases, post-releases, and local version identifiers that semantic versioning doesn't support

**Technical Skills:**
- HTTP client design with bounded concurrency using Go's errgroup package. You'll implement worker pools that prevent hammering APIs while maintaining parallelism.
- File-based caching with ETags and TTL expiration, the same pattern CloudFlare and Varnish use for edge caching
- Regex-based surgical editing to update dependency versions without destroying comments or formatting, a technique also used by Renovate and Dependabot

**Tools and Techniques:**
- PyPI Simple API (PEP 691) for fetching package metadata. This is the same endpoint pip uses, so you're seeing exactly what pip sees.
- OSV.dev vulnerability database for batch querying known CVEs across multiple ecosystems
- TOML parsing and manipulation in Go using pelletier/go-toml, with custom regex patterns to preserve formatting

## Prerequisites

Before starting, you should understand:

**Required knowledge:**
- Go fundamentals including goroutines, channels, and context. You need to know what `go func()` does and why `context.Context` matters for cancellation.
- HTTP APIs and REST patterns. You'll be calling PyPI and OSV.dev endpoints, parsing JSON responses, and handling rate limits.
- Basic security concepts like what a CVE is, why dependency versions matter, and how transitive dependencies create risk

**Tools you'll need:**
- Go 1.24+ - The project uses `for range N` syntax from Go 1.24 and `math.MinInt` constants
- `just` task runner (optional) - Justfile provides shortcuts for common tasks like `just lint` and `just test`
- A Python project with dependencies to test against, or use the provided `testdata/pyproject.toml`

**Helpful but not required:**
- Experience with Python packaging tools like pip, poetry, or uv. Understanding how `pyproject.toml` differs from `requirements.txt` helps.
- Knowledge of PEP 440 (Python versioning) and PEP 503 (package name normalization). The project implements both from scratch.

## Quick Start

Get the project running locally:

```bash
# Clone and navigate
cd PROJECTS/beginner/simple-vulnerability-scanner

# Install dependencies
go mod download

# Run against the test data
just dev-scan

# Or run directly
go run ./cmd/angela scan --file testdata/pyproject.toml
```

Expected output: angela will show you that packages like `django>=3.2,<4.0` and `requests>=2.28.0` are outdated, then list any known vulnerabilities with their severity levels (CRITICAL, HIGH, MODERATE, LOW) and fixed versions.

To actually update a file:

```bash
# Check what would change (dry run)
go run ./cmd/angela check --file testdata/pyproject.toml

# Update the file
go run ./cmd/angela update --file testdata/pyproject.toml

# Update AND scan for vulnerabilities
go run ./cmd/angela update --vulns --file testdata/pyproject.toml
```

## Project Structure

```
simple-vulnerability-scanner/
├── cmd/
│   └── angela/
│       └── main.go              # Entry point, calls cli.Execute()
├── internal/
│   ├── cli/                     # Cobra commands and output formatting
│   │   ├── update.go            # Main command logic
│   │   └── output.go            # Terminal UI with colors
│   ├── pypi/                    # PyPI Simple API client
│   │   ├── client.go            # HTTP client with caching
│   │   ├── cache.go             # File-based cache with ETag support
│   │   └── version.go           # PEP 440 version parser
│   ├── osv/                     # OSV.dev vulnerability scanner
│   │   └── client.go            # Batch vulnerability queries
│   ├── pyproject/               # pyproject.toml parser/writer
│   │   ├── parser.go            # Extract dependencies from TOML
│   │   └── writer.go            # Update versions preserving comments
│   ├── requirements/            # requirements.txt parser/writer
│   ├── config/                  # angela configuration loader
│   └── ui/                      # Terminal colors and spinners
├── pkg/types/                   # Shared type definitions
├── testdata/                    # Sample files for testing
├── Justfile                     # Task runner shortcuts
└── .golangci.yml               # Linter configuration
```

## Next Steps

1. **Understand the concepts** - Read [01-CONCEPTS.md](./01-CONCEPTS.md) to learn about supply chain security, CVE databases, and version resolution
2. **Study the architecture** - Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) to see how PyPI caching, concurrent requests, and vulnerability scanning fit together
3. **Walk through the code** - Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for line-by-line explanations of the PEP 440 parser, cache system, and regex-based file updates
4. **Extend the project** - Read [04-CHALLENGES.md](./04-CHALLENGES.md) for ideas like adding SBOM generation, transitive dependency scanning, or custom vulnerability sources

## Common Issues

**"Package not found on PyPI"**
```
Error: package "my-package" not found on PyPI
```
Solution: Check the package name spelling. PyPI normalizes names (underscores become dashes), so `my_package` and `my-package` are the same. The package might also be spelled differently than you think (e.g., `Pillow` not `PIL`).

**"Rate limit exceeded" when scanning many packages**
Solution: The PyPI Simple API has rate limits (roughly 10 requests/second). angela defaults to 10 concurrent workers (`internal/pypi/client.go:17`). If you hit limits, reduce `DefaultMaxWorkers`. The cache helps avoid repeated requests.

**Cache shows stale data**
Solution: Clear the cache with `angela cache clear` or manually delete `~/.angela/cache/`. The default TTL is 1 hour (`internal/pypi/cache.go:11`). For development, you might want to lower this.

**"Invalid TOML syntax" after update**
This should never happen (the updater validates before writing), but if it does: the regex pattern in `internal/pyproject/writer.go:90-99` might have matched something it shouldn't. File a bug with the original pyproject.toml content.

## Related Projects

If you found this interesting, check out:
- **api-rate-limiter** - Builds the HTTP rate limiting that PyPI and OSV.dev use to prevent abuse
- **package-vulnerability-db** - Shows how to build your own OSV.dev alternative with custom vulnerability sources
- **dependency-graph-analyzer** - Extends this to map transitive dependencies and find supply chain risks deeper in the tree
