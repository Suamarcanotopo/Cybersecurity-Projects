```ruby
██████╗  ██████╗ ██╗  ██╗████████╗ ██████╗  ██████╗ ██╗
██╔══██╗██╔════╝ ██║  ██║╚══██╔══╝██╔═══██╗██╔═══██╗██║
██████╔╝██║  ███╗███████║   ██║   ██║   ██║██║   ██║██║
██╔══██╗██║   ██║╚════██║   ██║   ██║   ██║██║   ██║██║
██████╔╝╚██████╔╝     ██║   ██║   ╚██████╔╝╚██████╔╝███████╗
╚═════╝  ╚═════╝      ╚═╝   ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝
```

[![Cybersecurity Projects](https://img.shields.io/badge/Cybersecurity--Projects-Project%20%2313-red?style=flat&logo=github)](https://github.com/CarterPerez-dev/Cybersecurity-Projects/tree/main/PROJECTS/beginner/base64-tool)
[![Python](https://img.shields.io/badge/Python-3.14+-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org)
[![License: AGPLv3](https://img.shields.io/badge/License-AGPL_v3-purple.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![PyPI](https://img.shields.io/pypi/v/b64tool?color=3775A9&logo=pypi&logoColor=white)](https://pypi.org/project/b64tool/)

> Multi-format encoding/decoding CLI with recursive layer detection for security analysis.

*This is a quick overview — security theory, architecture, and full walkthroughs are in the [learn modules](#learn).*

**[Screenshots & demo →](DEMO.md)**

## What It Does

- Encode and decode Base64, Base64URL, Base32, Hex, and URL formats
- Auto-detect encoding format with confidence scoring
- Peel command recursively strips multi-layered encoding (WAF bypass analysis)
- Chain multiple encoding steps to test obfuscation patterns
- Pipeline-friendly output for integration into security workflows

## Quick Start

```bash
uv tool install b64tool
b64tool encode "Hello World"
```

> [!TIP]
> This project uses [`just`](https://github.com/casey/just) as a command runner. Type `just` to see all available commands.
>
> Install: `curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin`

## Commands

| Command | Description |
|---------|-------------|
| `b64tool encode` | Encode text into Base64, Base64URL, Base32, Hex, or URL format |
| `b64tool decode` | Decode encoded text back to plaintext |
| `b64tool detect` | Auto-detect the encoding format with confidence scoring |
| `b64tool peel` | Recursively strip multi-layered encoding to reveal original data |
| `b64tool chain` | Chain multiple encoding steps together for obfuscation testing |

## Learn

This project includes step-by-step learning materials covering security theory, architecture, and implementation.

| Module | Topic |
|--------|-------|
| [00 - Overview](learn/00-OVERVIEW.md) | Prerequisites and quick start |
| [01 - Concepts](learn/01-CONCEPTS.md) | Security theory and real-world breaches |
| [02 - Architecture](learn/02-ARCHITECTURE.md) | System design and data flow |
| [03 - Implementation](learn/03-IMPLEMENTATION.md) | Code walkthrough |
| [04 - Challenges](learn/04-CHALLENGES.md) | Extension ideas and exercises |


## License

AGPL 3.0
