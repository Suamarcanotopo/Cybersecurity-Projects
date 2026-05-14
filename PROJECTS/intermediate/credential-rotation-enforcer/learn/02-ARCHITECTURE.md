<!--
©AngelaMos | 2026
02-ARCHITECTURE.md
-->

# Architecture

## System overview

```
┌─────────────────────────────────────────────────────────────┐
│                       cre  (single Crystal binary)          │
│                                                             │
│   ┌──────────────────────────────────────────────────────┐  │
│   │                   Event Bus                          │  │
│   │             (typed Crystal channels)                 │  │
│   └────┬─────┬─────┬─────┬─────┬─────┬─────┬────────────┘  │
│        │     │     │     │     │     │     │               │
│   ┌────▼─┐ ┌─▼──┐ ┌▼───┐ ┌▼──┐ ┌▼────┐ ┌──▼──┐ ┌──────┐    │
│   │Sched │ │Rot.│ │Pol.│ │TUI│ │Tele.│ │Audit│ │Notify│    │
│   │ulers │ │Reg │ │Eval│ │   │ │Bot  │ │Log  │ │      │    │
│   └──┬───┘ └─┬──┘ └─┬──┘ └───┘ └─────┘ └──┬──┘ └──────┘    │
│      │       │      │                     │                 │
│      └───────┴──────┴─────────────────────┘                 │
│                       │                                     │
│              ┌────────▼─────────┐                           │
│              │  Persistence     │ ◄── SQLite (Tier 1)       │
│              │  (PG / SQLite)   │ ◄── PostgreSQL (T2/T3)    │
│              └──────────────────┘                           │
└─────────────────────────────────────────────────────────────┘
```

All long-lived components are **fibers in one OS process**. The bus is in-process - Crystal channels are nanosecond-scale, so the architectural overhead is essentially free.

## Components

### Event Bus (`src/cre/engine/event_bus.cr`)

Fanout dispatch via Crystal channels. Each subscriber gets its own bounded channel and chooses an overflow policy:

| Subscriber | Overflow | Reason |
|---|---|---|
| `AuditSubscriber` | `Block` | Never drop audit events; compliance requirement |
| `Tui` | `Drop` | Stale UI is fine; can't block engine |
| `LogNotifier` | `Drop` | Best-effort structured logs |
| `TelegramSubscriber` | `Drop` (buffer 128) | Network-flaky anyway |
| `RotationWorker` | `Block` (buffer 32) | Must dispatch scheduled rotations |

The dispatcher is a single fiber reading from the inbox channel and writing to subscriber channels. Both overflow modes use `select` so a stuck subscriber can't pin the bus indefinitely:

- `Drop`: non-blocking `select … else …` — full buffer logs a warn and drops the event.
- `Block`: `select … when timeout(@block_send_timeout) …` — if a subscriber's buffer stays full past the timeout (default 5s), the bus drops that one event, logs the stall, and moves on. Operators tune the timeout up for slow downstreams they trust (audit DB writes) and down for unreliable ones.

### Rotators (`src/cre/rotators/`)

The abstract `Rotator` class exposes the four lifecycle methods plus `rollback_apply`. Concrete rotators self-register at compile time:

```crystal
class AwsSecretsRotator < Rotator
  register_as :aws_secretsmgr
  ...
end
```

Adding a fifth rotator means dropping a single file in `src/cre/rotators/`. The macro hooks it into the registry at compile time. No central wiring to update.

Rotators receive their cloud client through their constructor (DI). The CLI `run` command wires the right client based on env vars / config.

### Persistence (`src/cre/persistence/`)

Two adapters behind one interface:
- `Sqlite::SqlitePersistence` - single connection (`max_pool_size=1`) so SQLite's writer-serialization is safe; `synchronous=NORMAL`; `BEFORE UPDATE` and `BEFORE DELETE` triggers on `audit_events` raise `audit_events is append-only`. Application-level mutex for advisory-lock simulation (the abstraction is in-process only on SQLite). Used for Tier 1 demo.
- `Postgres::PostgresPersistence` - JSONB tags, `BIGSERIAL` audit seq, `audit_events_no_update` trigger refusing UPDATE/DELETE/TRUNCATE, `pg_advisory_xact_lock` for cross-process locking, and a partial unique index on `rotations(credential_id) WHERE state NOT IN ('completed','failed','aborted','inconsistent')` so two daemons can never insert overlapping in-flight rotations for the same credential. Used for Tier 2/3.

Both backends share the same migration runner (`schema_migrations` table + version-tracked `Step` records), so adding a column is a one-line `Step.new(N, ["ALTER TABLE ..."])` instead of editing a soup of `IF NOT EXISTS`. The repo contracts (`CredentialsRepo`, `VersionsRepo`, `RotationsRepo`, `AuditRepo`) are identical between adapters; `Persistence` exposes `transaction(&)` and `with_advisory_lock(key, &)` so the rest of the system stays backend-agnostic.

### Crypto layers (`src/cre/crypto/`, `src/cre/audit/`)

```
+--------------------+
|   Plaintext        |
+--------------------+
          |
          | AES-256-GCM(plain, DEK, AAD = tenant||cred||version, nonce 96b)
          v
+--------------------+
|  ciphertext + tag  | -> credential_versions.ciphertext
+--------------------+

+----+
| DEK| (32 random bytes per row)
+----+
   |
   | KEK_v.wrap(DEK)  (envelope encryption)
   v
+--------------------+
|   wrapped DEK       | -> credential_versions.dek_wrapped + kek_version
+--------------------+

KEK source (per tier):
  Tier 1: env var CRE_KEK_HEX (64-hex chars = 32 bytes)
  Tier 2: AWS KMS via LocalStack
  Tier 3: real AWS KMS or HSM
```

Per-row DEKs collapse the AES-GCM nonce-reuse birthday concern (each row's DEK encrypts exactly one message). AAD-binding prevents ciphertext-swap attacks where an attacker with DB write tries to swap a low-privilege row's ciphertext into a high-privilege row.

`algorithm_id` is reserved for crypto agility:
- `0x01` = AES-256-GCM (today)
- `0x02` = XChaCha20-Poly1305 (long nonce, simpler)
- `0x03` = ML-KEM hybrid wrap (post-quantum forward secrecy)

### Audit log integrity stack

Three layers, increasingly hard to bypass:

```
+-------------------------------------------------+
|  Layer 3: Ed25519-signed Merkle batches         |
|    audit_batches table, hourly seal, signed     |
|    over (start_seq, end_seq, root)              |
|    Auditor verifies with public key only.       |
+-------------------------------------------------+
                    |
                    | leaves: content_hash[]
                    v
+-------------------------------------------------+
|  Layer 2: HMAC ratchet                          |
|    K_v signs each row's content_hash; every     |
|    1024 rows -> K_{v+1} = HKDF(K_v, "ratchet"); |
|    K_v zeroized in memory                       |
+-------------------------------------------------+
                    |
                    v
+-------------------------------------------------+
|  Layer 1: Hash chain                            |
|    content_hash = SHA256(prev_hash ||           |
|                          canonical_payload)     |
|    rendering single-row tampering visible       |
+-------------------------------------------------+
                    |
                    v
+-------------------------------------------------+
|  PostgreSQL audit_events table                  |
|    - INSERT-only role grant                     |
|    - UPDATE/DELETE/TRUNCATE trigger refuses     |
+-------------------------------------------------+
```

The PG triggers are not strictly necessary (the chain catches tampering anyway), but they fail loud at write-time which is much friendlier for operators. SQLite tier 1 documents the relaxed guarantee.

## Concurrency

| Scope | Bound | Mechanism |
|---|---|---|
| Per-credential | 1 active rotation | `RotationWorker` checks `rotations.in_flight` before dispatching; PG also enforces a partial unique index so cross-process duplicates fail at the DB |
| Per-rotation lifecycle | 1 step at a time | Orchestrator runs `generate -> apply -> verify -> commit` sequentially; `rollback_apply` fires on apply/verify failure; commit failure marks the rotation `inconsistent` and raises a critical alert |
| Engine event bus | per-subscriber buffer + timeout | `EventBus#dispatch` uses `select` for both Block and Drop overflow (see Bus subscribers table above) |

Crystal fibers + bounded channels = clean rate limiting without threads or locks.

## Lifecycle (cre run)

```
1. Bootstrap: validate CRE_HMAC_KEY_HEX + CRE_KEK_HEX (hard-fail if missing)
2. Open persistence (PG or SQLite); migrate! (versioned Step list)
3. Build Envelope from KEK; build optional Ed25519Signer from CRE_SIGNING_KEY_HEX
4. Load compiled-in policies (REGISTRY) + register rotators from env vars
5. Start EventBus.run (dispatcher fiber)
6. Start subscribers: AuditSubscriber, LogNotifier, RotationWorker, PolicyEvaluator
7. Start Scheduler (SchedulerTick every CRE_TICK_SECONDS)
8. Start BatchSealerScheduler if signer present (default every 5min)
9. Wire Telegram bot if TELEGRAM_TOKEN + chat IDs are set
10. Optionally start TUI + Snapshotter (cre watch)
11. Block on stop_signal channel; SIGINT triggers graceful drain
```

Graceful shutdown: `engine.stop` publishes `ShutdownRequested` and waits up to 2s on `audit_subscriber.await_drain` — the audit subscriber sends on a private completion channel as soon as it processes that event, which proves it has handled everything queued before it. Then the bus closes its inbox and subscriber channels; each subscriber fiber exits on `Channel::ClosedError`.
