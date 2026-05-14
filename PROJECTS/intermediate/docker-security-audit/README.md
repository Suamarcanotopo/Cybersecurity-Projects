```regex
██████╗  ██████╗  ██████╗██╗  ██╗███████╗███████╗ ██████╗
██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝██╔════╝██╔════╝██╔════╝
██║  ██║██║   ██║██║     █████╔╝ ███████╗█████╗  ██║
██║  ██║██║   ██║██║     ██╔═██╗ ╚════██║██╔══╝  ██║
██████╔╝╚██████╔╝╚██████╗██║  ██╗███████║███████╗╚██████╗
╚═════╝  ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝
```

[![Cybersecurity Projects](https://img.shields.io/badge/Cybersecurity--Projects-Project%20%238-red?style=flat&logo=github)](https://github.com/CarterPerez-dev/Cybersecurity-Projects/tree/main/PROJECTS/intermediate/docker-security-audit)
[![Go](https://img.shields.io/badge/Go-1.25+-00ADD8?style=flat&logo=go&logoColor=white)](https://go.dev)
[![License: AGPLv3](https://img.shields.io/badge/License-AGPL_v3-purple.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Go Report Card](https://goreportcard.com/badge/github.com/CarterPerez-dev/docksec)](https://goreportcard.com/report/github.com/CarterPerez-dev/docksec)
[![Docker](https://img.shields.io/badge/Docker-required-2496ED?style=flat&logo=docker)](https://www.docker.com)

> Docker security audit CLI that checks containers, images, and Dockerfiles against CIS Docker Benchmark v1.6.0.

*This is a quick overview — security theory, architecture, and full walkthroughs are in the [learn modules](#learn).*

## What It Does

- Scans running containers, images, Dockerfiles, and compose files for misconfigurations
- Checks against CIS Docker Benchmark v1.6.0 with severity scoring
- Detects privileged containers, dangerous capabilities, socket mounts, and namespace sharing
- Outputs terminal (colored), JSON, SARIF (GitHub Security tab), and JUnit formats
- Supports severity filtering and fail-on-critical for CI/CD pipelines
- Validates AppArmor/seccomp profiles, resource limits, and user namespace remapping

## Quick Start

```bash
go install github.com/CarterPerez-dev/docksec/cmd/docksec@latest
docksec scan
```

> [!TIP]
> This project uses [`just`](https://github.com/casey/just) as a command runner. Type `just` to see all available commands.
>
> Install: `curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin`

## Commands

```bash
docksec scan                                    # scan all targets with colored output
docksec scan --format sarif -o results.sarif    # export SARIF for GitHub Security tab
docksec scan --severity critical,high           # filter by severity
docksec scan --fail-on critical                 # exit non-zero for CI pipelines
```

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
