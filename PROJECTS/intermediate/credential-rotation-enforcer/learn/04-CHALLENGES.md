<!--
©AngelaMos | 2026
04-CHALLENGES.md
-->

# Extension Challenges

Pick one and ship it as a PR.

## Beginner

### 1. Add a fifth rotator: PostgreSQL `ALTER USER`
A new file `src/cre/rotators/postgres_user.cr` that rotates a Postgres role's password directly via `ALTER USER ... PASSWORD ...`. Use the existing 4-step contract; verify by opening a fresh connection with the new password. Drop the file in - the macro registers it automatically. Add unit specs in `spec/unit/rotators/postgres_user_spec.cr`.

### 2. Slack notifier subscriber
Mirror `TelegramSubscriber` against Slack's `chat.postMessage`. Add chat ID allowlist, channel-id parameterization, and message formatting. Single new file in `src/cre/notifiers/`.

### 3. Add `notify_via :slack` to the Channel enum
Once you have a Slack notifier, add `Slack` to `Channel` in `src/cre/policy/policy.cr`, dispatch on it in the evaluator, and write a policy in `policies/` that uses it.

## Intermediate

### 4. Web dashboard via SSE
Add `src/cre/web/` with a Lucky/Kemal HTTP server that subscribes to the bus and pushes events as Server-Sent Events to an HTMX dashboard. Reuse `Tui::State` as the data model - it already has the right shape. The point of the bus + plugin architecture is that this is a *new subscriber*, not a rewrite.

### 5. ML-KEM hybrid wrap for KEK
Add `algorithm_id = 0x03` to envelope encryption: hybrid Curve25519 + ML-KEM-768 (Kyber) for the DEK wrap. Provides forward secrecy against future quantum-attack on captured ciphertexts. Note: ML-KEM is in OpenSSL 3.x; you may need to update LibCrypto FFI bindings.

### 6. OpenTimestamps anchoring
Anchor each `audit_batches` Merkle root to the Bitcoin blockchain via OpenTimestamps. Adds a fourth integrity layer: even if the entire DB and signing key are compromised, an offline auditor with a Bitcoin full node can verify when each batch existed. Update `src/cre/audit/batch_sealer.cr` to publish OTS proofs alongside Ed25519 signatures.

## Advanced

### 7. SPIFFE/SPIRE workload identity rotator
Add a rotator that *replaces* static credentials with SPIFFE SVIDs (X.509 + JWT). Demonstrates the post-2024 industry shift away from rotation entirely toward attestation-based ephemeral identity. Touch points: new client in `src/cre/spiffe/`, new rotator in `src/cre/rotators/spiffe.cr`, new credential kind in `src/cre/domain/credential.cr`.

### 8. Crash recovery state machine
The orchestrator already marks commit-step failures as `Inconsistent` and emits a critical alert, so single-step partial failures surface loudly. What's still missing is the *boot-time* recovery sweep: if the daemon was killed between, say, a successful `apply` and the start of `verify`, the `rotations` row is left in `Verifying` state with no fiber driving it forward. Implement the recovery protocol: on boot, scan `rotations` for non-terminal states; for each, decide based on `(rotator_kind, last_step)` whether to invoke `rollback_apply`, retry from the failed step, or transition to `Inconsistent`. Add `src/cre/engine/recovery.cr` with explicit state-machine semantics, wire it into `Engine#start`, and add a SQL fixture spec in `spec/unit/engine/recovery_spec.cr` that builds each kind of "stale" row and asserts the right outcome.

### 9. Multi-tenant support
Wire `tenant_id` end-to-end: a new migration adds the column on `credentials` / `credential_versions` / `rotations` / `audit_events`; the AAD construction in `RotationOrchestrator#persist_credential_version` extends to `cred=<id>|kind=<k>|tenant=<t>`; policy matchers gain `c.tenant == "tenant-x"`; and Postgres row-level security policies enforce isolation at the DB level. The biggest design decision: per-tenant KEKs (each tenant rotates independently, but bootstrap juggles N keys) vs shared KEK with tenant-bound DEKs (simpler config, the AAD does the isolation work).

### 10. JIT credential broker
Replace the rotation contract entirely for some credential types: instead of rotating, *issue* a fresh ephemeral credential on each access (5-15 minute TTL). Requires a new `Broker` abstraction alongside `Rotator`, integration with AWS STS / GCP service account impersonation / Vault dynamic, and consumer-side token refresh logic in the example apps.

## Evaluation rubric (for self-review)

A great extension PR:
- Has unit tests in `spec/unit/<area>/` mirroring the source layout
- Has a focused commit message explaining the *why*, not just the *what*
- Doesn't break existing tests (`crystal spec spec/` should be green)
- Adds 1-3 file-level changes; if it touches more than 5 files, the abstraction is probably wrong
- Surfaces failure modes honestly (e.g., the JIT broker should clearly document the consumer-side complexity it shifts)
