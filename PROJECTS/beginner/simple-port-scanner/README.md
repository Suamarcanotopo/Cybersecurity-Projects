```ruby
██████╗  ██████╗ ██████╗ ████████╗    ███████╗ ██████╗ █████╗ ███╗   ██╗███╗   ██╗███████╗██████╗
██╔══██╗██╔═══██╗██╔══██╗╚══██╔══╝    ██╔════╝██╔════╝██╔══██╗████╗  ██║████╗  ██║██╔════╝██╔══██╗
██████╔╝██║   ██║██████╔╝   ██║       ███████╗██║     ███████║██╔██╗ ██║██╔██╗ ██║█████╗  ██████╔╝
██╔═══╝ ██║   ██║██╔══██╗   ██║       ╚════██║██║     ██╔══██║██║╚██╗██║██║╚██╗██║██╔══╝  ██╔══██╗
██║     ╚██████╔╝██║  ██║   ██║       ███████║╚██████╗██║  ██║██║ ╚████║██║ ╚████║███████╗██║  ██║
╚═╝      ╚═════╝ ╚═╝  ╚═╝   ╚═╝       ╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝
```

[![Cybersecurity Projects](https://img.shields.io/badge/Cybersecurity--Projects-Project%20%237-red?style=flat&logo=github)](https://github.com/CarterPerez-dev/Cybersecurity-Projects/tree/main/PROJECTS/beginner/simple-port-scanner)
[![C++20](https://img.shields.io/badge/C++-20-00599C?style=flat&logo=cplusplus)](https://isocpp.org)
[![License: AGPLv3](https://img.shields.io/badge/License-AGPL_v3-purple.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![CMake](https://img.shields.io/badge/CMake-3.31+-064F8C?style=flat&logo=cmake)](https://cmake.org)

> Asynchronous TCP port scanner built with C++ and Boost.Asio for high-concurrency network reconnaissance.

*This is a quick overview — security theory, architecture, and full walkthroughs are in the [learn modules](#learn).*
> *Developed by [@deniskhud](https://github.com/deniskhud)*

## What It Does

- Asynchronous TCP port scanning using Boost.Asio for high concurrency
- Configurable port ranges from single ports to full 65535 scans
- Adjustable concurrency level to control scan speed and network load
- Connection timeout configuration to handle filtered ports gracefully
- Clean terminal output showing open, closed, and filtered port states

## Quick Start

```bash
mkdir build && cd build
cmake ..
make
./simplePortScanner --target 192.168.1.1 --ports 1-1024
```

> [!TIP]
> This project uses [`just`](https://github.com/casey/just) as a command runner. Type `just` to see all available commands.
>
> Install: `curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin`

## Building

**Requirements:** C++20 compiler, Boost library, CMake >= 3.31

```bash
./simplePortScanner --target 10.0.0.1 --ports 22,80,443 --concurrency 200
./simplePortScanner --target 172.16.0.5 --ports 1-65535 --timeout 500
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
