# Binary Analysis Tool: Overview

## What This Is

AXUMORTEM is a static binary analysis engine that parses ELF, PE, and Mach-O executables, runs them through a six-pass analysis pipeline, and produces a threat score with MITRE ATT&CK technique mapping. Upload a binary, get back a full breakdown: headers, imports, strings, entropy, disassembly, and a 0-100 threat score.

## Why This Matters

Binary analysis is the first thing that happens when a suspicious file lands on an analyst's desk. Every malware triage workflow starts here: what format is it, what does it import, is it packed, what strings leak intent.

When the SolarWinds SUNBURST backdoor was discovered in December 2020, it was binary analysis that revealed the trojanized `SolarWinds.Orion.Core.BusinessLayer.dll`. Analysts found that the DLL's import table included unexpected network APIs, its strings contained hardcoded C2 domain generation logic, and its entropy profile showed sections that didn't match a legitimate .NET assembly. That single analysis kicked off one of the largest incident response efforts in history.

In 2017, the CCleaner supply chain attack (Avast's own build server) shipped a trojanized PE binary to 2.27 million users. The backdoor was caught because researchers noticed the binary's sections had anomalous entropy and the import table included `VirtualAlloc` + `CreateRemoteThread`, the classic process injection chain. A tool like AXUMORTEM flags exactly that combination.

More recently, the 3CX supply chain compromise (March 2023) embedded a trojanized DLL inside the legitimate desktop client. Static analysis of the binary revealed encrypted shellcode payloads hidden in high-entropy sections, anti-analysis strings referencing debugger detection, and suspicious import chains that pointed to process hollowing. The attack affected over 600,000 organizations worldwide.

## What You'll Learn

**Security concepts:**
- How ELF, PE, and Mach-O binary formats work at the byte level
- What entropy tells you about packing, encryption, and obfuscation
- How YARA rules detect malware families, packers, and evasion techniques
- How threat scoring systems quantify risk from static indicators
- MITRE ATT&CK technique identification from API imports

**Technical skills:**
- Building a modular analysis pipeline with dependency-ordered passes
- Parsing binary formats with the `goblin` crate
- x86/x86_64 disassembly and control flow graph construction
- YARA rule compilation and scanning with `yara-x`
- Shannon entropy calculation and classification
- Full-stack architecture: Rust/Axum backend with React/TypeScript frontend

**Tools and techniques:**
- Rust workspace organization with multiple crates
- Axum HTTP framework with multipart file uploads
- SQLx compile-time checked queries against PostgreSQL
- React 19 with TanStack Query for async data fetching
- Zod schema validation on the frontend
- Docker Compose for production and development environments

## Prerequisites

**Required knowledge:**
- Comfortable reading Rust (ownership, traits, enums, pattern matching)
- Basic understanding of how executables work (sections, headers, linking)
- Familiarity with web APIs (REST, JSON, HTTP status codes)
- React/TypeScript fundamentals (components, hooks, routing)

**Helpful but not required:**
- x86 assembly (the disassembly module will teach you the basics)
- YARA rule syntax (covered in the concepts module)
- Malware analysis experience (this project is designed to build that skill)

**Needed tools:**
- Docker and Docker Compose
- Rust toolchain (for local development)
- Node.js 22+ and pnpm (for frontend development)
- `just` command runner (optional but recommended)

## Quick Start

```bash
git clone https://github.com/CarterPerez-dev/Cybersecurity-Projects.git
cd Cybersecurity-Projects/PROJECTS/intermediate/binary-analysis-tool

docker compose up -d
```

Visit `http://localhost:22784` and upload a binary. You should see:

```
Analysis complete
Format: ELF | Architecture: x86_64 | Size: 15.2 KB
Threat Score: 12/100 (BENIGN)
```

For development with hot reload:

```bash
docker compose -f dev.compose.yml up -d
```

Frontend dev server runs on `http://localhost:15723`, backend API on port `3000`.

## Project Structure

```
binary-analysis-tool/
├── backend/
│   └── crates/
│       ├── axumortem-engine/          # Core analysis library
│       │   └── src/
│       │       ├── lib.rs             # Engine entry — orchestrates all passes
│       │       ├── types.rs           # BinaryFormat, Architecture, RiskLevel enums
│       │       ├── context.rs         # AnalysisContext — carries results between passes
│       │       ├── pass.rs            # AnalysisPass trait + PassManager (topo sort)
│       │       ├── yara.rs            # YARA scanner with 14 built-in rules
│       │       ├── formats/           # ELF, PE, Mach-O parsers
│       │       └── passes/            # The six analysis passes
│       │           ├── format.rs      # 1. Binary format detection
│       │           ├── imports.rs     # 2. Import/export extraction
│       │           ├── strings.rs     # 3. String extraction + categorization
│       │           ├── entropy.rs     # 4. Shannon entropy + packing detection
│       │           ├── disasm.rs      # 5. x86/x86_64 disassembly + CFG
│       │           └── threat.rs      # 6. Threat scoring (8 categories, 100pt max)
│       │
│       └── axumortem/                 # HTTP server
│           └── src/
│               ├── main.rs            # Axum server with graceful shutdown
│               ├── routes/            # upload, analysis retrieval, health check
│               ├── db/                # PostgreSQL models, queries, migrations
│               └── middleware/        # CORS configuration
│
├── frontend/
│   └── src/
│       ├── api/                       # Axios client, Zod schemas, React Query hooks
│       ├── pages/
│       │   ├── landing/               # Drag-drop upload interface
│       │   └── analysis/              # Tabbed results (overview, headers, imports, ...)
│       └── config.ts                  # Risk level colors, route definitions
│
├── infra/docker/                      # Dockerfiles for production builds
├── compose.yml                        # Production: nginx + backend + postgres
├── dev.compose.yml                    # Development: vite + backend + postgres
└── justfile                           # Command runner recipes
```

## Next Steps

| Next | Topic |
|------|-------|
| [01 - Concepts](01-CONCEPTS.md) | Binary format internals, entropy theory, YARA rules, threat modeling |
| [02 - Architecture](02-ARCHITECTURE.md) | Pass pipeline design, data flow, component interactions |
| [03 - Implementation](03-IMPLEMENTATION.md) | Code walkthrough with real snippets from each pass |
| [04 - Challenges](04-CHALLENGES.md) | Build extensions: new passes, new formats, dashboards |

## Common Issues

**Docker build fails on `yara-x`:**
The `yara-x` crate requires `protobuf-compiler` at build time. The production Dockerfile installs it, but if building locally you need `apt install protobuf-compiler` (Debian/Ubuntu) or `brew install protobuf` (macOS).

**SQLx compile-time errors:**
SQLx checks queries against the database at compile time. If the database isn't running, set `SQLX_OFFLINE=true` to use cached query metadata. The `sqlx-data.json` file in the repo provides this cache.

**Frontend can't reach the API:**
In development mode, the Vite dev server proxies `/api` requests to the backend. Make sure the backend container is running on port 3000. Check `dev.compose.yml` for the correct port mappings.

**Analysis returns empty disassembly:**
Disassembly only runs on x86 and x86_64 binaries. ARM and AArch64 binaries will have all other passes complete normally, but the disassembly tab will be empty.

## Related Projects

| Project | Connection |
|---------|------------|
| [Network Traffic Analyzer](../../beginner/network-traffic-analyzer/) | Captures traffic that binary analysis can correlate with C2 communication |
| [SIEM Dashboard](../siem-dashboard/) | Ingests analysis results as security events for centralized monitoring |
| [Encrypted P2P Chat](../../advanced/encrypted-p2p-chat/) | Uses cryptographic primitives that binary entropy analysis would flag |
