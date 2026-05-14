```ruby
███╗   ██╗███████╗████████╗ █████╗ ███╗   ██╗ █████╗ ██╗
████╗  ██║██╔════╝╚══██╔══╝██╔══██╗████╗  ██║██╔══██╗██║
██╔██╗ ██║█████╗     ██║   ███████║██╔██╗ ██║███████║██║
██║╚██╗██║██╔══╝     ██║   ██╔══██║██║╚██╗██║██╔══██║██║
██║ ╚████║███████╗   ██║   ██║  ██║██║ ╚████║██║  ██║███████╗
╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝
```

[![Cybersecurity Projects](https://img.shields.io/badge/Cybersecurity--Projects-Project%20%2312-red?style=flat&logo=github)](https://github.com/CarterPerez-dev/Cybersecurity-Projects/tree/main/PROJECTS/beginner/network-traffic-analyzer)
[![Python](https://img.shields.io/badge/Python-3.14+-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org)
[![License: AGPLv3](https://img.shields.io/badge/License-AGPL_v3-purple.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![PyPI](https://img.shields.io/pypi/v/netanal?color=3775A9&logo=pypi&logoColor=white)](https://pypi.org/project/netanal/)

> Network traffic capture and analysis CLI with protocol distribution, top talkers, and bandwidth visualization.

*This is a quick overview — security theory, architecture, and full walkthroughs are in the [learn modules](#learn).*

## What It Does

- Capture live network traffic on any interface with configurable packet counts
- Real-time protocol distribution analysis with percentage breakdowns
- Top talkers identification showing most active IP addresses by traffic volume
- Bandwidth calculation with bytes sent/received per endpoint
- Verbose mode displays individual packet flow with source/destination details
- Built on Scapy for deep packet inspection and protocol parsing

## Quick Start

```bash
uv tool install netanal
sudo netanal capture -i eth0 -c 100
```

> [!TIP]
> This project uses [`just`](https://github.com/casey/just) as a command runner. Type `just` to see all available commands.
>
> Install: `curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin`

## Commands

| Command | Description |
|---------|-------------|
| `netanal capture` | Live packet capture with protocol analysis, top talkers, and bandwidth stats |

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
