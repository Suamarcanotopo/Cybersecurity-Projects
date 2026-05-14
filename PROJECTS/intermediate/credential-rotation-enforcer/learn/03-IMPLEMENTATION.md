<!--
©AngelaMos | 2026
03-IMPLEMENTATION.md
-->

# Implementation Walkthrough

This document points you at the most important code paths. Read it with `tree src/` open in another window.

## The Policy DSL (statically- and registration-time validated)

`src/cre/policy/dsl.cr` declares the DSL inside `module CRE::Policy::Dsl`. Consumers opt in explicitly:

```crystal
require "cre/policy/dsl"
include CRE::Policy::Dsl

policy "production-aws-secrets" do
  match { |c| c.kind.aws_secretsmgr? && c.tag(:env) == "prod" }
  max_age 30.days
  enforce :rotate_immediately
  notify_via :telegram, :structured_log
end
```

`with builder yield` makes every Builder method callable receiver-less inside the block. Two flavors of typo-detection apply:

- **Compile time** — `enforce :rotate_immediatly` (single Symbol arg → `Action` enum) is rejected by Crystal's autocast. `match { |c| c.kund }` (typo on a Credential getter) breaks compilation pointing at the policy file.
- **Registration time** — `notify_via :telegrm, :slak` uses a splat-Symbol overload that runs `Channel.parse?` on each value and raises `BuilderError("unknown channel 'telegrm' in policy '<name>'")` when the file is loaded. Splat autocast doesn't reach into Symbols, so this layer is the next-best thing.

`Builder#build` also raises `BuilderError` on missing required fields (`matcher`, `max_age`, `enforce_action`). Either way, a misformed policy never reaches a running daemon.

## The Event Bus (fanout via Crystal channels)

`src/cre/engine/event_bus.cr` exposes `subscribe(buffer:, overflow:)` returning a `Channel(Event)`. The `run` method spawns a single dispatcher fiber that reads from `@inbox` and forwards to each subscriber's channel.

`dispatch` uses Crystal's `select` for both overflow modes:
- `Drop` — `select … else` drops the event when the buffer is full and logs a warn.
- `Block` — `select … when timeout(@block_send_timeout)` waits up to `@block_send_timeout` (default 5s) and only then drops, logging the stall. This isolates the bus from a stuck subscriber: head-of-line blocking is bounded.

## The Rotator Plugin Registration

`src/cre/rotators/rotator.cr` declares an abstract base with a class-level `REGISTRY = {} of Symbol => Rotator.class`. The macro `register_as` populates this at compile time:

```crystal
abstract class Rotator
  REGISTRY = {} of Symbol => Rotator.class

  macro register_as(kind)
    ::CRE::Rotators::Rotator::REGISTRY[{{ kind }}] = self
  end
end
```

When a file like `src/cre/rotators/aws_secrets.cr` is required, the `register_as :aws_secretsmgr` line runs at *compile time* and the class shows up in `Rotator::REGISTRY[:aws_secretsmgr]`. No central list to maintain.

## The 4-step Orchestrator

`src/cre/engine/rotation_orchestrator.cr` runs the contract:

```
generate -> rotator-specific (often produces the new value + cloud version_id)
apply    -> rotator-specific (often no-op for cloud rotators where generate already exposed)
verify   -> read back, byte-equal check
commit   -> promote new -> AWSCURRENT, demote old -> AWSPREVIOUS
```

Each step publishes `RotationStepStarted` and either `RotationStepCompleted` or `RotationStepFailed` to the bus.

Failure handling has two regimes:

- **apply or verify fails** — `rotator.rollback_apply(c, new_secret)` reverses the cloud-side mutation; rotation moves to `Failed`; bus emits `RotationStepFailed` + `RotationFailed`.
- **commit fails** — partial cross-call commit sequences (e.g., AWS `UpdateSecretVersionStage` 5xx half-way through) cannot be reliably reversed client-side. The rotation transitions to `Inconsistent` (a terminal state distinct from `Failed`), and the orchestrator emits a critical `AlertRaised` so operators know to intervene.

Success path is now the heavyweight one: when the four steps complete, the orchestrator
1. seals `new_secret.ciphertext` with the optional `Crypto::Envelope` (AES-256-GCM, AAD = `cred=<id>|kind=<k>`),
2. inserts a `credential_versions` row with the wrapped DEK + KEK version,
3. updates the credential row to bump `last_rotated_at`, set `current_version_id` to the new version's id, and demote the old one to `previous_version_id`.

That last step is what stops the policy evaluator from re-scheduling the same rotation on every tick — `Policy#overdue?` keys on `c.rotation_anchor` (which is `last_rotated_at || created_at`), not on `updated_at`.

The orchestrator never directly calls audit. Audit happens automatically because `AuditSubscriber` is on the bus listening for these exact event types — the orchestrator can't forget to log. And because the orchestrator's path is the only path that runs `versions.insert` + `credentials.update`, persistence-side state stays consistent with the audit-log narrative.

## SigV4 Signer (the AWS-flavored work)

`src/cre/aws/signer.cr` implements RFC-style AWS SigV4:

```
canonical_request = method + canonical_uri + canonical_query +
                    canonical_headers + signed_headers + payload_hash
string_to_sign    = "AWS4-HMAC-SHA256\n" + amz_date + "\n" +
                    credential_scope + "\n" + sha256(canonical_request)
signing_key       = HMAC chain (kSecret -> kDate -> kRegion -> kService -> kSigning)
signature         = HMAC(signing_key, string_to_sign)
```

The `Authorization` header is built from `algorithm + Credential=... + SignedHeaders=... + Signature=...`. Includes `X-Amz-Security-Token` when an STS session token is supplied.

Two test files cover the signer:
- `spec/unit/aws/signer_spec.cr` — idempotence + Authorization-header regex shape.
- `spec/unit/aws/signer_aws_vector_spec.cr` — uses the AWS reference suite's `get-vanilla` inputs (access key, secret, region, service, fixed timestamp) and locks in a regression vector for the exact signature our signer produces. Because we always emit `X-Amz-Content-SHA256` (required by Secrets Manager and other JSON-protocol services), the signed-headers list is `host;x-amz-content-sha256;x-amz-date` — slightly different from AWS's vanilla vector, so we lock in our own bytes rather than match theirs. Any future change to canonicalization, key derivation, or header ordering trips the test.

## Audit Log Integrity (three-layer)

`src/cre/audit/audit_log.cr` writes Layers 1 + 2 on every `append`:
- `latest_hash` from the DB (genesis = 32 zero bytes for an empty log)
- `content_hash = HashChain.next_hash(prev_hash, canonical_payload)`
- `hmac = HmacRatchet#sign(content_hash)`; ratchet rolls every 1024 rows
- All three columns plus `hmac_key_version` get persisted in one `INSERT` per row

Verification is split into three independently-callable methods:
- `verify_hash_chain` — walks every entry, recomputes `SHA256(prev_hash || payload)`, compares against `content_hash`.
- `verify_hmac_ratchet(seed_key)` — replays the ratchet from the seed `CRE_HMAC_KEY_HEX`, recomputes each row's HMAC against `content_hash`, and checks `hmac_key_version` matches the ratchet's view of where rotation should be. Catches an attacker who fixed up the hash chain but doesn't have the seed.
- `verify_batches(verifier)` — for every row in `audit_batches`, refetch the corresponding `content_hash` leaves, recompute the Merkle root, then verify the Ed25519 signature over `(start_seq, end_seq, root)`.

`src/cre/audit/batch_sealer.cr` builds Layer 3 entries:
- Walk new audit_events since `last_sealed_seq`
- Build a Merkle tree (`Merkle.root`) over each row's `content_hash`
- Sign `(start_seq, end_seq, root)` with Ed25519 via `Signing::Ed25519Signer`
- Insert into `audit_batches`

`src/cre/audit/batch_sealer_scheduler.cr` is the fiber that actually drives the sealer in `cre run` / `cre watch`: it calls `seal_pending` once on start, again every `CRE_SEAL_INTERVAL_SECONDS` (default 300s), and once more on shutdown. Every successful seal publishes a typed `AuditBatchSealed` event, which the audit subscriber writes back into the audit log under `audit.batch.sealed` — closing the loop with the SOC 2 / PCI-DSS / ISO / HIPAA control mapping that already keys on that event type.

Crystal's stdlib OpenSSL doesn't expose Ed25519 high-level wrappers, so `src/cre/audit/signing.cr` reaches into LibCrypto via FFI: `EVP_PKEY_new_raw_private_key`, `EVP_DigestSign`, etc. Public-key verification is symmetrical: `Ed25519Verifier#verify(message, signature)`.

## AEAD Envelope Encryption

`src/cre/crypto/aead.cr` does AES-256-GCM via LibCrypto FFI (stdlib `OpenSSL::Cipher` doesn't expose `auth_data=` / `auth_tag` for GCM). The envelope (`src/cre/crypto/envelope.cr`) generates a 32-byte DEK per row, encrypts plaintext with AES-256-GCM(plaintext, DEK, AAD), then wraps the DEK with KEK using a separate AEAD (with its own AAD `kek-wrap|v<version>`). Both ciphertexts are `nonce(12) || tag(16) || body`.

Decrypting requires the KEK to unwrap the DEK, then the DEK + AAD to decrypt the payload. AAD mismatch fails tag verification at the inner layer; KEK version mismatch fails at unwrap.

## TUI

`src/cre/tui/state.cr` holds a rolling view of active rotations + recent events. `apply(ev)` is the single entry point that mutates state; pure update logic, easy to test.

`src/cre/tui/renderer.cr` paints the four panels to any IO. ANSI escapes via `src/cre/tui/ansi.cr` (stdlib only). The renderer's `pad` helper accounts for ANSI escape widths so column alignment is correct under colors.

`src/cre/tui/tui.cr` ties it together: subscribes to the bus (Drop overflow), spawns a tick fiber + an event fiber, both calling `maybe_render` which throttles to `refresh_interval`.

## Telegram Bot

`src/cre/notifiers/telegram.cr` is a thin HTTP::Client wrapper for the Telegram Bot API (no tourmaline dependency for the notification path). Errors get the bot token redacted before they hit logs — Telegram requires the token in the URL path, so the redaction is best-effort, but it stops the obvious leak.

`src/cre/notifiers/telegram_bot.cr` does long-poll `getUpdates` and dispatches commands. Auth is by chat-ID allowlist; viewer tier (`/status`, `/queue`, `/history`, `/alerts`) is read-only; operator tier adds `/rotate`. `/rotate <id>` publishes `RotationScheduled` to the bus, which the `RotationWorker` consumes (see `src/cre/engine/rotation_worker.cr`) — the worker resolves the credential, looks up the right `Rotator` from the env-driven dispatch table, checks `rotations.in_flight` to dedupe, and hands off to `RotationOrchestrator`.

## Persistence Layer Shape

`src/cre/persistence/repos.cr` declares the abstract repos (`CredentialsRepo`, `VersionsRepo`, `RotationsRepo`, `AuditRepo`) and the record types (`RotationRecord`, `AuditEntry`, `AuditBatch`, plus the `RotatorKind` and `RotationState` enums). `RotationState::Inconsistent` is included in `TERMINAL_STATES` alongside `Completed` / `Failed` / `Aborted`.

Both adapters apply schema changes through `Migrations::Step` records keyed on a monotonic `version`. The `schema_migrations` table tracks which versions have run; new alterations land as new `Step.new(N, ["ALTER TABLE ..."])` entries instead of editing the soup of `IF NOT EXISTS` statements.

`audit_events` is the most carefully guarded table in the schema:
- Postgres has the original `audit_events_no_update` trigger (raises `audit_events is append-only` on UPDATE/DELETE/TRUNCATE).
- SQLite gets parity via two `BEFORE UPDATE` / `BEFORE DELETE` triggers using `RAISE(ABORT, '...')`.
- The repo's `INSERT` no longer uses `OR IGNORE` / `ON CONFLICT … DO NOTHING`, so a constraint failure raises into the application instead of silently dropping.
- The audit subscriber's rescue path publishes a critical `AlertRaised` and (by default) panics the process via `CRE_AUDIT_FAILURE_MODE=panic`.

Two independent layers; both must be subverted to forge history.
