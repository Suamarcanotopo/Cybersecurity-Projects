<!--
©AngelaMos | 2026
README.md
-->

```regex
 ██████╗██████╗ ███████╗
██╔════╝██╔══██╗██╔════╝
██║     ██████╔╝█████╗
██║     ██╔══██╗██╔══╝
╚██████╗██║  ██║███████╗
 ╚═════╝╚═╝  ╚═╝╚══════╝
```

[![Cybersecurity Projects](https://img.shields.io/badge/Cybersecurity--Projects-Project%20%2327%20intermediate-red?style=flat&logo=github)](https://github.com/CarterPerez-dev/Cybersecurity-Projects/tree/main/PROJECTS/intermediate/credential-rotation-enforcer)
[![Crystal](https://img.shields.io/badge/Crystal-1.20+-black?style=flat&logo=crystal&logoColor=white)](https://crystal-lang.org)
[![License: AGPLv3](https://img.shields.io/badge/License-AGPL_v3-purple.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-336791?style=flat&logo=postgresql&logoColor=white)](https://www.postgresql.org)

> Credential rotation enforcer written in Crystal. Tracks credentials, evaluates compile-time-checked policies, and executes the four-step rotation contract against AWS Secrets Manager, HashiCorp Vault, GitHub fine-grained PATs, and local `.env` files. Single binary, live TUI, bidirectional Telegram bot, tamper-evident audit log, signed compliance evidence export.

*This is a quick overview — security theory, architecture, and full walkthroughs are in the [learn modules](#learn). Operator setup lives in [CONFIGURATION.md](CONFIGURATION.md).*

## What It Does

- Compile-time-checked policy DSL (typo'd action symbols, missing fields, bad credential property references all fail `crystal build`)
- Bus + plugin architecture — typed events fan out across Crystal channels; subscribers (audit, TUI, Telegram, log) react independently; rotators register at compile time via `register_as :kind` macro
- Four-step rotation contract (`generate → apply → verify → commit`) borrowed from AWS Secrets Manager's rotation Lambda template, dual-version safe under concurrent reads
- Three-layer tamper-evident audit log: SHA-256 hash chain + ratcheting HMAC-SHA256 + Ed25519-signed Merkle batches
- AEAD envelope encryption (AES-256-GCM, per-row DEKs wrapped by KEK, AAD-bound to credential identity, reserved `algorithm_id` byte for crypto agility)
- Hand-rolled live TUI (no external TUI framework — stdlib ANSI escapes only) with event-driven repaints coalesced to a tick interval
- Bidirectional Telegram bot — viewer tier (`/status`, `/queue`, `/history`, `/alerts`) + operator tier (`/rotate`)
- Compliance evidence export bundle (signed ZIP with audit log, Merkle batches, control mapping for SOC 2 / PCI-DSS / ISO 27001 / HIPAA)

## Quick Start

```bash
git clone https://github.com/CarterPerez-dev/Cybersecurity-Projects.git
cd Cybersecurity-Projects/PROJECTS/intermediate/credential-rotation-enforcer
shards install && shards build cre --release
./bin/cre demo
```

Or use the install script:

```bash
curl -fsSL https://raw.githubusercontent.com/CarterPerez-dev/Cybersecurity-Projects/main/PROJECTS/intermediate/credential-rotation-enforcer/scripts/install.sh | bash
```

> [!TIP]
> This project uses [`just`](https://github.com/casey/just) as a command runner. Type `just` to see all available recipes.
>
> Install: `curl -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin`

### Demo tiers

```bash
just demo               # Tier 1 — zero-deps SQLite + .env rotator (under 30s)
just tui-demo           # Live TUI preview with synthetic events (8s, no setup)
just demo-full          # Tier 2 — Docker Compose: PG + LocalStack + Vault + fake-GH
just demo-full-down     # tear down the stack
```

### Daemon usage

`cre run` and `cre watch` require two 32-byte secrets — the seed key for the audit-log HMAC ratchet and the KEK that wraps per-row data keys. Generate fresh values once and store them somewhere durable (KMS, password manager, sealed env file):

```bash
export CRE_HMAC_KEY_HEX=$(openssl rand -hex 32)
export CRE_KEK_HEX=$(openssl rand -hex 32)
export CRE_SIGNING_KEY_HEX=$(openssl rand -hex 32)   # optional: enables Merkle-batch sealing
```

Then:

```bash
cre run --db=sqlite:cre.db                       # headless daemon
cre watch --db=sqlite:cre.db                     # daemon + live TUI
cre check --db=sqlite:cre.db --output=json       # one-shot CI gate (no key required)
cre rotate <credential-id>                       # manual rotation (uses same env-driven rotators as run)
cre policy list                                  # inspect compiled policies
cre audit verify                                 # hash chain + HMAC ratchet (+ Merkle if --public-key given)
cre export --framework=soc2 --out=evidence.zip   # signed compliance bundle
cre verify-bundle evidence.zip                   # offline re-verify a bundle
```

`cre check` exits 1 when any credential violates its policy — drop into any CI pipeline.

## Flagship Rotators

| Rotator | What it talks to | Auth |
|---|---|---|
| AWS Secrets Manager | `secretsmanager.<region>.amazonaws.com` | SigV4 (rolled from scratch in `src/cre/aws/signer.cr`) |
| HashiCorp Vault | `vault read database/creds/<role>` + lease revoke | `X-Vault-Token` |
| GitHub fine-grained PATs | `POST/DELETE /user/personal-access-tokens` | `Bearer ghp_...` |
| Local `.env` file | atomic temp+rename | n/a |

Adding a fifth rotator means dropping a single file in `src/cre/rotators/` — the `register_as :kind` macro hooks it into the registry at compile time. Zero changes to the orchestrator, scheduler, or any subscriber.

## Architecture

```
                       ┌──────────────────────────────────────┐
                       │       cre  (single Crystal binary)   │
                       │                                      │
   ┌────────────┐      │  ┌──────────────────────────────┐    │
   │ Scheduler  │─────►│  │       Typed Event Bus        │    │
   │ (fiber)    │      │  └──┬─────┬─────┬─────┬─────┬───┘    │
   └────────────┘      │     │     │     │     │     │        │
                       │  ┌──▼──┐ ┌▼────┐ ┌▼──┐ ┌▼──┐ ┌▼───┐  │
                       │  │Rot. │ │Audit│ │TUI│ │Tg │ │Pol.│  │
                       │  │Wrkr │ │Sub  │ │Sub│ │Bot│ │Eval│  │
                       │  └──┬──┘ └──┬──┘ └───┘ └───┘ └────┘  │
                       │     │       │                        │
                       │     ▼       ▼                        │
                       │  ┌──────────────────────────────┐    │
                       │  │  Persistence (PG / SQLite)   │    │
                       │  │  + 3-layer audit integrity   │    │
                       │  └──────────────────────────────┘    │
                       └──────────────────────────────────────┘
```

All long-lived components are fibers in one OS process. The bus is in-process (Crystal channels are nanosecond-scale) so the architectural overhead is essentially free. Per-subscriber overflow policy: `Block` for audit (compliance — never drop), `Drop` for TUI / metrics / Telegram (best-effort).

## The Three-Layer Audit Log

```
   Layer 3 ─ Ed25519-signed Merkle batches  →  auditor verifies with public key only
   Layer 2 ─ HMAC ratchet (key zeroized per rotation)  →  past entries unforgeable
   Layer 1 ─ SHA-256 hash chain  →  any single-row tampering breaks forward chain
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
   Postgres ─ append-only via TRIGGER + role grants (INSERT-only)
```

`cre audit verify` walks all three layers and reports which (if any) is broken.

## Stack

**Language:** Crystal 1.20+

**Dependencies:** crystal-db (DB abstraction), crystal-pg (PostgreSQL), crystal-sqlite3 (SQLite), tourmaline (Telegram framework, used minimally), webmock.cr (test HTTP mocks)

**Direct LibCrypto FFI** for AES-256-GCM AEAD (Crystal stdlib `OpenSSL::Cipher` lacks GCM auth_data/auth_tag) and Ed25519 signing (stdlib lacks high-level wrapper). Bindings live in `src/cre/crypto/aead.cr` and `src/cre/audit/signing.cr`.

**Testing:** stdlib `Spec` runner, 179+ unit tests + integration tests against real PostgreSQL via Docker.

## Configuration

Setup is fully env-var driven — no config file required. See **[CONFIGURATION.md](CONFIGURATION.md)** for the operator guide:

- Required env vars (`CRE_KEK_HEX`, `CRE_HMAC_KEY_HEX`, `DATABASE_URL`)
- Per-rotator setup (AWS IAM policy, Vault token policy, GitHub admin PAT)
- Telegram bot creation + chat-ID discovery
- systemd service unit with hardening directives
- Production security checklist

## Learn

This project includes step-by-step learning materials covering security theory, architecture, and implementation.

| Module | Topic |
|--------|-------|
| [00 - Overview](learn/00-OVERVIEW.md) | Prerequisites, quick start, three-tier demo path |
| [01 - Concepts](learn/01-CONCEPTS.md) | Rotation theory, real breaches, NIST/SOC2/PCI/ISO/HIPAA framework controls |
| [02 - Architecture](learn/02-ARCHITECTURE.md) | Bus + plugin design, persistence layers, three-layer audit integrity, AEAD envelope |
| [03 - Implementation](learn/03-IMPLEMENTATION.md) | Code-level walkthrough; where to look in source for each concept |
| [04 - Challenges](learn/04-CHALLENGES.md) | 10 ranked extension challenges (PG ALTER USER, Slack, ML-KEM, OpenTimestamps, SPIFFE, JIT broker, etc.) |

## License

AGPL 3.0
