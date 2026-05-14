```ruby
 ██████╗ █████╗ ███████╗███████╗ █████╗ ██████╗
██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗██╔══██╗
██║     ███████║█████╗  ███████╗███████║██████╔╝
██║     ██╔══██║██╔══╝  ╚════██║██╔══██║██╔══██╗
╚██████╗██║  ██║███████╗███████║██║  ██║██║  ██║
 ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝
```

[![Cybersecurity Projects](https://img.shields.io/badge/Cybersecurity--Projects-Project%20%2310-red?style=flat&logo=github)](https://github.com/CarterPerez-dev/Cybersecurity-Projects/tree/main/PROJECTS/beginner/caesar-cipher)
[![Python](https://img.shields.io/badge/Python-3.12+-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org)
[![License: AGPLv3](https://img.shields.io/badge/License-AGPL_v3-purple.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![PyPI](https://img.shields.io/pypi/v/caesar-salad-cipher?color=3775A9&logo=pypi&logoColor=white)](https://pypi.org/project/caesar-salad-cipher/)

> Caesar cipher encryption, decryption, and brute-force cracking CLI with frequency analysis.

*This is a quick overview — security theory, architecture, and full walkthroughs are in the [learn modules](#learn).*

**[Screenshots & demo →](DEMO.md)**

## What It Does

- Encrypt text using Caesar cipher with a specified shift key
- Decrypt ciphertext back to plaintext with the original key
- Brute-force crack unknown ciphertext by testing all 26 shifts
- Frequency analysis ranking to identify the most likely plaintext
- Clean Rich terminal output with colored tables

## Quick Start

```bash
uv tool install caesar-salad-cipher
caesar-cipher encrypt "HELLO WORLD" --key 3
```

> [!TIP]
> This project uses [`just`](https://github.com/casey/just) as a command runner. Type `just` to see all available commands.
>
> Install: `curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin`

## Commands

| Command | Description |
|---------|-------------|
| `caesar-cipher encrypt` | Encrypt plaintext using a specified shift key |
| `caesar-cipher decrypt` | Decrypt ciphertext back to plaintext with the original key |
| `caesar-cipher crack` | Brute-force all 26 shifts with frequency analysis ranking |

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
