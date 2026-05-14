# Overview

## What This Project Does

b64tool is a multi-format encoding/decoding CLI that handles Base64, Base64URL, Base32, hex, and URL encoding. The standout feature is recursive layer peeling, which automatically detects and decodes multiple stacked encoding layers, the same technique attackers use to obfuscate malware payloads and bypass web application firewalls.

You give it an encoded blob. It figures out what format it is, decodes it, checks if the result is itself encoded, and keeps going until it reaches the original data. Think of it like an onion. Each layer is a different encoding, and the tool peels them one at a time.

## Why This Exists

In real security work, you constantly encounter encoded data. JWT tokens are base64. Certificates are base64. Hex dumps show up in packet captures and malware analysis. URL encoding appears in every web request. And when attackers want to hide payloads, they don't just encode once. They stack encodings: base64 the payload, hex encode that, then URL encode the hex. This tool handles all of that.

## What You'll Learn

- How Base64, Base32, hex, and URL encoding actually work at the byte level
- Why encoding is not encryption (and why confusing them causes real vulnerabilities)
- Pattern recognition for identifying encoding formats
- How attackers layer encodings for obfuscation (with real examples from DARKGATE malware)
- Building a clean, typed Python CLI with typer and rich
- Confidence-based detection algorithms

## Prerequisites

- Python 3.14+
- `uv` package manager
- Basic command line comfort
- Understanding of bytes vs strings (helpful, not required)

## Quick Start

```bash
cd PROJECTS/beginner/base64-tool
uv sync
uv run b64tool --help
```

### Try the basics

```bash
uv run b64tool encode "Hello World"
# Output: SGVsbG8gV29ybGQ=

uv run b64tool decode "SGVsbG8gV29ybGQ="
# Output: Hello World

uv run b64tool detect "SGVsbG8gV29ybGQ="
# Shows: base64, 95% confidence
```

### Try multi-layer encoding

```bash
uv run b64tool chain "alert('xss')" --steps base64,hex
# Produces a hex-encoded base64 string

uv run b64tool peel "5957786c636e516f4a33687a63796370"
# Peels: hex → base64 → alert('xss')
```

### Pipe support

```bash
echo "SGVsbG8=" | uv run b64tool decode
cat encoded_payload.txt | uv run b64tool peel
```

## Project Structure

```
base64-tool/
├── src/base64_tool/
│   ├── cli.py          # Typer commands (encode, decode, detect, peel, chain)
│   ├── constants.py    # Enums, thresholds, character sets
│   ├── encoders.py     # Pure encode/decode functions + registry
│   ├── detector.py     # Format detection with confidence scoring
│   ├── peeler.py       # Recursive multi-layer decoding
│   ├── formatter.py    # Rich terminal output
│   └── utils.py        # Input resolution, text helpers
├── tests/              # 78 tests across all modules
├── pyproject.toml      # Python 3.14, typer, rich
└── Justfile            # Task runner shortcuts
```

## Next Steps

- [01-CONCEPTS.md](./01-CONCEPTS.md) - How encoding works, real CVEs, encoding vs encryption
- [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) - System design, module relationships, data flow
- [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) - Code walkthrough with file references
- [04-CHALLENGES.md](./04-CHALLENGES.md) - Extension ideas from easy to expert
