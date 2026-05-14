```ruby
███╗   ███╗███████╗████████╗
████╗ ████║██╔════╝╚══██╔══╝
██╔████╔██║███████╗   ██║
██║╚██╔╝██║╚════██║   ██║
██║ ╚═╝ ██║███████║   ██║
╚═╝     ╚═╝╚══════╝   ╚═╝
```

[![Cybersecurity Projects](https://img.shields.io/badge/Cybersecurity--Projects-Project%20%239-red?style=flat&logo=github)](https://github.com/CarterPerez-dev/Cybersecurity-Projects/tree/main/PROJECTS/beginner/metadata-scrubber-tool)
[![Python](https://img.shields.io/badge/Python-3.10+-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org)
[![License: AGPLv3](https://img.shields.io/badge/License-AGPL_v3-purple.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![PyPI](https://img.shields.io/pypi/v/metadata-scrubber?color=3775A9&logo=pypi&logoColor=white)](https://pypi.org/project/metadata-scrubber/)

> Privacy-focused CLI that strips sensitive metadata from images, PDFs, and Office documents.

*This is a quick overview — security theory, architecture, and full walkthroughs are in the [learn modules](#learn).*

**[Screenshots & demo →](DEMO.md)**
> *Developed by [@Heritage-XioN](https://github.com/Heritage-XioN)*
## What It Does

- Strip metadata from JPEG, PNG, PDF, Word, Excel, and PowerPoint files
- Concurrent processing with ThreadPoolExecutor handles 1000+ files efficiently
- Dry-run mode previews what would be removed before making changes
- Verification reports show before/after comparison of metadata fields
- Smart format detection uses file signatures, not extensions
- Removes GPS coordinates, author info, timestamps, camera data, and software traces

## Quick Start

```bash
uv tool install metadata-scrubber
mst scrub photo.jpg
```

> [!TIP]
> This project uses [`just`](https://github.com/casey/just) as a command runner. Type `just` to see all available commands.
>
> Install: `curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin`

## Commands

| Command | Description |
|---------|-------------|
| `mst read <file>` | Inspect metadata fields present in a file |
| `mst scrub <file>` | Remove all metadata from a file |
| `mst verify <file>` | Confirm metadata was successfully removed |

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
