```ruby
 ██████╗██████╗     ██████╗ ███████╗ █████╗  ██████╗ ██████╗ ███╗   ██╗
██╔════╝╚════██╗    ██╔══██╗██╔════╝██╔══██╗██╔════╝██╔═══██╗████╗  ██║
██║      █████╔╝    ██████╔╝█████╗  ███████║██║     ██║   ██║██╔██╗ ██║
██║     ██╔═══╝     ██╔══██╗██╔══╝  ██╔══██║██║     ██║   ██║██║╚██╗██║
╚██████╗███████╗    ██████╔╝███████╗██║  ██║╚██████╗╚██████╔╝██║ ╚████║
 ╚═════╝╚══════╝    ╚═════╝ ╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝
```

[![Cybersecurity Projects](https://img.shields.io/badge/Cybersecurity--Projects-Project%20%2315-red?style=flat&logo=github)](https://github.com/CarterPerez-dev/Cybersecurity-Projects/tree/main/PROJECTS/beginner/c2-beacon)
[![Python](https://img.shields.io/badge/Python-3.13+-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org)
[![React](https://img.shields.io/badge/React-19-61DAFB?style=flat&logo=react&logoColor=black)](https://react.dev)
[![License: AGPLv3](https://img.shields.io/badge/License-AGPL_v3-purple.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Docker](https://img.shields.io/badge/Docker-ready-2496ED?style=flat&logo=docker)](https://www.docker.com)
[![MITRE ATT&CK](https://img.shields.io/badge/MITRE-ATT%26CK-red?style=flat)](https://attack.mitre.org/)

> Command and Control beacon and server with XOR-encoded WebSocket protocol, 10 MITRE ATT&CK mapped commands, and a real-time operator dashboard.

*This is a quick overview — security theory, architecture, and full walkthroughs are in the [learn modules](#learn).*

## What It Does

- WebSocket-based C2 protocol with XOR + Base64 encoding and shared-key authentication
- 10 beacon commands mapped to MITRE ATT&CK: shell, sysinfo, proclist, upload, download, screenshot, keylog, persist, sleep
- Real-time operator dashboard showing connected beacons with live heartbeat tracking
- Terminal-style session page with command history, tab autocomplete, and inline screenshot rendering
- Per-beacon async task queues with SQLite persistence and full task history
- Exponential backoff reconnection with configurable sleep interval and jitter

## Quick Start

```bash
docker compose -f dev.compose.yml up -d
```

Visit `http://localhost:47430` to open the operator dashboard.

Run a beacon in a separate terminal:

```bash
just beacon
```

> [!TIP]
> This project uses [`just`](https://github.com/casey/just) as a command runner. Type `just` to see all available commands.
>
> Install: `curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin`

## Stack

**Backend:** FastAPI, aiosqlite, Pydantic, uvicorn

**Frontend:** React 19, TypeScript, Vite, Zustand, Zod

**Beacon:** asyncio, websockets, psutil, pynput, mss

## Learn

This project includes step-by-step learning materials covering security theory, architecture, and implementation.

| Module | Topic |
|--------|-------|
| [00 - Overview](learn/00-OVERVIEW.md) | Prerequisites and quick start |
| [01 - Concepts](learn/01-CONCEPTS.md) | C2 frameworks, MITRE ATT&CK, and detection |
| [02 - Architecture](learn/02-ARCHITECTURE.md) | Protocol design and data flow |
| [03 - Implementation](learn/03-IMPLEMENTATION.md) | Code walkthrough |
| [04 - Challenges](learn/04-CHALLENGES.md) | Extension ideas and exercises |


## License

AGPL 3.0

<img width="1827" height="853" alt="Screenshot_20260214_022250" src="https://github.com/user-attachments/assets/9f26428f-53cc-49be-84cc-346357e8ef00" />

<img width="1103" height="828" alt="Screenshot_20260214_022135" src="https://github.com/user-attachments/assets/27876356-ec9d-4a0f-af71-92c3c7714232" />

