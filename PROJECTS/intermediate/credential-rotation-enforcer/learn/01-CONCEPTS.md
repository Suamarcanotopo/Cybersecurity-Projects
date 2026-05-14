<!--
©AngelaMos | 2026
01-CONCEPTS.md
-->

# Concepts - Credential Rotation, in Practice and in History

## Why credential rotation is its own discipline

A credential is a fact in shared state: "this token authorizes this principal." The longer that fact stays in shared state, the more places it can leak from. Compromise has a half-life: every commit, every CI log, every laptop, every backup tape extends the radius. Rotation is the discipline of forcing the fact to expire on a schedule **shorter than the time-to-discover** of the leakage paths you can't see.

The post-2020 industry consensus has shifted significantly:

- **NIST SP 800-63B-4** (final July 2025): *prohibits* periodic password rotation for human credentials, BUT continues to require rotation for service accounts, API keys, machine identities.
- **NIST SP 800-57 Pt1 Rev5**: cryptoperiod-driven rotation per key type (DEKs, KEKs, signing keys, MACs).
- **PCI DSS v4.0.1** (mandatory March 2025): the 90-day rule still defaults; the "Customized Approach" off-ramp lets you replace it with continuous monitoring + risk-based rotation.
- **CA/Browser Forum SC-081v3**: TLS certificate lifetimes shrink to 47 days by 2029.

So the practical answer in 2026 is not "rotate everything every 90 days" - it's **risk-based rotation** for human credentials, **cryptoperiod-driven rotation** for keys, and **JIT / ephemeral / workload-identity** for the highest-risk service-to-service paths.

## Real breaches that motivated this design

| Year | Incident | Root credential failure |
|---|---|---|
| 2020 | SolarWinds Sunburst | Service account token reused for ~9 months across attacker dwell |
| 2021 | Codecov bash uploader | One leaked GCS upload key, no rotation, 2 months of supply-chain access |
| 2022 | Heroku/Travis OAuth | OAuth tokens for npm reuse - no rotation, no scope reduction |
| 2023 | Storm-0558 (Microsoft) | MSA signing key generated 2016, never rotated, leaked via crash dump |
| 2023 | Okta support breach | HAR files containing session tokens - no exfil-detection, no token binding |
| 2024 | Snowflake / UNC5537 | Customer credentials leaked years prior, never rotated, no MFA |
| 2024 | Microsoft Midnight Blizzard | Legacy non-prod tenant test creds, never rotated |
| 2025 | tj-actions CVE-2025-30066 | GitHub Actions token theft via supply-chain action |

The pattern repeats: **time** is the attacker's ally. Each row above had at least one credential that lived too long in shared state.

## What this enforcer prevents (and doesn't)

**Prevents:**
- Stale credentials living past their expected lifetime (policy violation -> notify or auto-rotate)
- Silent rotation drift (current-vs-DB-fingerprint detection)
- Forgetting to log a rotation (audit-log automatic via bus subscriber - the orchestrator can't bypass it)
- Audit-log tampering (3-layer integrity: chain + HMAC ratchet + Ed25519 batch signing)
- Unauthorized rotation triggers (Telegram bot ACL, CLI requires explicit credential ID)

**Does NOT prevent:**
- Compromise of the KEK itself (use AWS KMS / HSM in production)
- Attacker who already exfiltrated a valid credential before rotation (rotate ASAP, but the fact already escaped)
- Insider running `cre rotate <id>` legitimately but with malicious intent (audit log captures it; doesn't stop it)
- DNS hijack of api.telegram.org (use webhooks with mTLS for hardened deployments)

## The Four-Step Rotation Contract, Explained

Borrowed verbatim from AWS Secrets Manager's Rotation Lambda template. The rule is: **between step 2 and step 4, both old AND new credentials are valid.** This is the dual-version safety guarantee. Concurrent consumers using either credential succeed; nobody crashes mid-rotation.

```
                     time -->
   step 1 (generate)    step 2 (apply)    step 3 (verify)    step 4 (commit)
        |                   |                   |                   |
   old: usable          old: usable         old: usable          old: REVOKED
   new: pending         new: usable         new: usable          new: current
        |                                                            |
        +-- rollback OK --+                +--+--+                   v
        upstream pending     verify failed?   |    irreversible
        artifact deletable   rollback_apply   |
                             revokes new      |
                                              v
                                              if verify passes,
                                              proceed to commit
```

Step 4 is the only **irreversible** step. By design. If step 4 fails partially (commit succeeded for new but old wasn't actually revoked), the orchestrator marks the rotation `inconsistent` and surfaces an alert - we honestly tell you "this needs a human" rather than silently corrupting state.

## Audit-log integrity, three layers deep

| Layer | Mechanism | Defends against |
|---|---|---|
| **Hash chain** | Each row's `content_hash = SHA256(prev_hash || canonical_payload)` | Silent edits - any change breaks the forward chain |
| **HMAC ratchet** | Each row HMAC'd with key K_v; every 1024 rows derive K_{v+1} = HKDF(K_v, "ratchet") and zeroize K_v | An attacker who later gets DB write + current key still cannot rewrite past entries (the old key is gone) |
| **Ed25519 Merkle batches** | Hourly: build Merkle root over `content_hash` leaves; sign root with Ed25519 | Auditor can verify with **only the public key + the batches**, no DB access required |

Verification is exposed as a CLI command:
```
$ cre audit verify --public-key=/etc/cre/audit_pubkey.hex
  ✓  hash chain: OK
  ✓  HMAC ratchet: OK
  ✓  Merkle batches: OK
✓ audit chain valid: 14892 entries
```

The HMAC ratchet replays from the seed key supplied via `CRE_HMAC_KEY_HEX`, so the verifier needs the *same* seed the writer used. Merkle batches are signed under `CRE_SIGNING_KEY_HEX` and verified with the matching public key — bundled in the `cre export` ZIP so an offline auditor can `cre verify-bundle` without DB access.

## Compliance Framework Coverage

The export bundle (`cre export --framework=soc2`) maps audit events to specific framework controls. Per `src/cre/compliance/control_mapping.cr`:

- **SOC 2** - CC6.1 (logical access mgmt), CC6.6 (vulnerability mgmt), CC6.7 (access review), CC4.1 (monitoring), CC7.1 / CC7.2 (incident detection)
- **PCI DSS v4.0.1** - 8.3.9 / 8.6.3 (auth & rotation), 10.5.x (audit log integrity), 3.7.4 (key management)
- **ISO 27001:2022** - A.5.16 / A.5.17 / A.5.18 (identity & access), A.8.5 (secure auth), A.8.15 / A.8.16 (logging & monitoring), A.8.24 (cryptography)
- **HIPAA Security Rule** - 164.308(a)(5)(ii)(D) (password mgmt), 164.312(b) (audit controls)
