<!--
©AngelaMos | 2026
CONFIGURATION.md
-->

# Configuration Guide

Step-by-step setup for running `cre` against real systems. Read top-to-bottom on first install; come back as a reference later.

> **TL;DR:** `cre` is configured entirely via **environment variables** (no config file required). Every integration is opt-in — set the env vars for the integrations you want, leave the rest unset, and the daemon adapts. Run `cre run` and watch the boot output to see which integrations actually wired up.

---

## Table of contents

1. [Required env vars](#1-required-env-vars)
2. [Database setup (Postgres)](#2-database-setup-postgres)
3. [Generate the cryptographic keys](#3-generate-the-cryptographic-keys)
4. [Define your policies](#4-define-your-policies)
5. [Seed your inventory](#5-seed-your-inventory)
6. [Wire AWS Secrets Manager](#6-wire-aws-secrets-manager)
7. [Wire HashiCorp Vault](#7-wire-hashicorp-vault)
8. [Wire GitHub fine-grained PATs](#8-wire-github-fine-grained-pats)
9. [Wire Telegram (notifications + commands)](#9-wire-telegram-notifications--commands)
10. [Run as a systemd service](#10-run-as-a-systemd-service)
11. [Verify and audit](#11-verify-and-audit)
12. [Key rotation (the KEK / HMAC keys themselves)](#12-key-rotation-the-kek--hmac-keys-themselves)
13. [Security checklist before production](#13-security-checklist-before-production)

---

## 1. Required env vars

Bare minimum to boot:

```bash
export DATABASE_URL="sqlite:/var/lib/cre/cre.db"   # or postgres://...
export CRE_KEK_HEX="$(openssl rand -hex 32)"        # 64 hex chars (32 bytes)
export CRE_HMAC_KEY_HEX="$(openssl rand -hex 32)"   # 64 hex chars (32 bytes)
```

Optional but worth setting:

```bash
export CRE_TICK_SECONDS=60          # scheduler interval (default: 60)
export CRE_DB_PATH=/var/lib/cre/cre.db  # used by 'cre audit verify' default
```

Everything else (AWS, Vault, GitHub, Telegram) is **opt-in** — set those vars only if you want those integrations.

---

## 2. Database setup (Postgres)

For production, use Postgres. SQLite is for the Tier 1 demo and small single-host deployments.

### Create the database

```bash
sudo -u postgres psql <<SQL
CREATE USER cre WITH PASSWORD 'change-me-strong';
CREATE DATABASE cre_prod OWNER cre;
\c cre_prod
GRANT ALL PRIVILEGES ON SCHEMA public TO cre;
SQL
```

### Set DATABASE_URL

```bash
export DATABASE_URL="postgres://cre:change-me-strong@db.internal:5432/cre_prod"
```

### Migrations

`cre run` calls `persist.migrate!` automatically on first boot, which creates all tables, indexes, append-only triggers, and grants. No manual migration step needed.

### Hardening (optional but recommended)

After first migrate, demote the app role to INSERT-only on the audit table:

```sql
REVOKE ALL ON audit_events FROM cre;
GRANT INSERT, SELECT ON audit_events TO cre;
GRANT USAGE, SELECT ON SEQUENCE audit_events_seq_seq TO cre;
```

This means even an SQL-injection attacker with the app's connection string can't `UPDATE` or `DELETE` audit rows — they get a permission-denied error in addition to the trigger refusing.

---

## 3. Generate the cryptographic keys

Two distinct keys, both 32 random bytes (64 hex chars):

```bash
openssl rand -hex 32   # use for CRE_KEK_HEX
openssl rand -hex 32   # use for CRE_HMAC_KEY_HEX
```

| Variable | What it does | Loss impact |
|---|---|---|
| `CRE_KEK_HEX` | Wraps every per-row DEK that encrypts a credential ciphertext | **All credentials become unreadable**. KEK is the master crypto root. |
| `CRE_HMAC_KEY_HEX` | Initial HMAC key for the audit-log ratchet | Audit log can't be HMAC-verified after this point; hash chain still works. Old logs (signed under earlier ratchet generations) remain verifiable independently. |

### Where to store these

- **Tier 1 / dev:** plain env vars in your shell or `.envrc` (gitignored)
- **Production:** AWS KMS, HashiCorp Vault transit engine, or your secrets manager. Inject at process boot via systemd `LoadCredentialEncrypted=` or similar.
- **Never:** in Git, even in private repos. Even in `.env` files committed by accident.

> Future versions will support `CRE_KEK_KMS=arn:...` to load directly from AWS KMS. Today it's env-only.

---

## 4. Define your policies

Policies are **Crystal source files** in `policies/`. They're compiled into the binary, so changes require a rebuild — but the compiler validates them, which means you can't ship a typo.

### Example: `policies/production.cr`

```crystal
require "../src/cre/policy/dsl"
include CRE::Policy::DSL

policy "aws-prod-databases" do
  description "Prod RDS credentials rotate every 30 days"
  match    { |c| c.kind.aws_secretsmgr? && c.tag(:env) == "prod" }
  max_age  30.days
  warn_at  25.days
  enforce  :rotate_immediately
  notify_via :telegram, :structured_log
  on_rotation_failure :alert_critical
end

policy "github-bots" do
  description "GitHub bot PATs notify-only at 90 days"
  match    { |c| c.kind.github_pat? && c.tag(:purpose) == "ci" }
  max_age  90.days
  warn_at  83.days
  enforce  :notify_only
  notify_via :telegram
end

policy "vault-dynamic-aggressive" do
  description "Vault dynamic DB creds rotate weekly"
  match    { |c| c.kind.vault_dynamic? }
  max_age  7.days
  enforce  :rotate_immediately
  notify_via :structured_log
end

policy "all-local-env-files" do
  match    { |c| c.kind.env_file? }
  max_age  30.days
  enforce  :rotate_immediately
end
```

### Validation

`crystal build` compiles policies and runs three independent checks:

1. **Enum autocast** — `enforce :foo_bar` fails if `:foo_bar` isn't an `Action`
2. **Typed Proc matchers** — `c.kund` (typo) fails because `Credential` has no `kund` method
3. **Required-fields check** — Builder raises if `match`, `max_age`, or `enforce` is missing

If `cre` ships, the policies are well-formed — period.

### Available enum values

| `enforce` | `notify_via` (any combination) | `on_rotation_failure` / `on_drift_detected` |
|---|---|---|
| `:rotate_immediately` | `:telegram` | `:rotate_immediately` |
| `:notify_only` | `:email` (placeholder) | `:notify_only` |
| `:quarantine` | `:structured_log` | `:quarantine` |
|  | `:pagerduty` (placeholder) |  |

---

## 5. Seed your inventory

`cre` doesn't auto-discover credentials. You tell it what exists by inserting rows into the `credentials` table. Each rotator looks for specific tags.

### Tag schema by rotator kind

| `kind` | Required tags | Optional tags |
|---|---|---|
| `AwsSecretsmgr` | `secret_arn` | `value_length` (default 32), `env`, `team` |
| `VaultDynamic` | `role_path` (e.g. `database/creds/myrole`) | `current_lease_id` (set after first rotation) |
| `GithubPat` | `name`, `scopes` (JSON array as string), `old_pat_id` | `expires_in_days` (default 90) |
| `EnvFile` | `path`, `key` | `bytes` (default 32) |

### Seed examples

#### AWS Secrets Manager credential

```sql
INSERT INTO credentials (id, external_id, kind, name, tags, created_at, updated_at)
VALUES (
  gen_random_uuid(),
  'arn:aws:secretsmanager:us-east-1:123456789012:secret:db-prod-rw',
  'AwsSecretsmgr',
  'db-prod-rw',
  '{"env":"prod","team":"platform","value_length":"24"}'::jsonb,
  now(),
  now()
);
```

#### Vault dynamic-secrets credential

```sql
INSERT INTO credentials (id, external_id, kind, name, tags, created_at, updated_at)
VALUES (
  gen_random_uuid(),
  'database/creds/postgres-readonly',
  'VaultDynamic',
  'postgres-readonly',
  '{"role_path":"database/creds/postgres-readonly"}'::jsonb,
  now(),
  now()
);
```

#### GitHub fine-grained PAT

```sql
INSERT INTO credentials (id, external_id, kind, name, tags, created_at, updated_at)
VALUES (
  gen_random_uuid(),
  'gh-deploy-bot',
  'GithubPat',
  'deploy-bot',
  '{"name":"deploy-bot","scopes":"[\"repo\",\"read:org\"]","old_pat_id":"12345","expires_in_days":"90"}'::jsonb,
  now(),
  now()
);
```

> The `old_pat_id` field gets updated by the rotator after each rotation (the new PAT becomes the next "old"). For the first seed, set it to your existing PAT's id (find it via GitHub UI or `GET /user/personal-access-tokens`).

#### Local `.env` file

```sql
INSERT INTO credentials (id, external_id, kind, name, tags, created_at, updated_at)
VALUES (
  gen_random_uuid(),
  '/etc/myapp/.env::API_KEY',
  'EnvFile',
  'myapp-API_KEY',
  '{"path":"/etc/myapp/.env","key":"API_KEY","bytes":"32"}'::jsonb,
  now(),
  now()
);
```

> Make sure the `cre` user has read+write permission on the file's parent directory (it writes `.env.pending` and renames atomically).

---

## 6. Wire AWS Secrets Manager

### IAM permissions

Create an IAM user (or assumable role) with this policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CreRotation",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecretVersionStage",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:*:*:secret:cre-managed/*"
    }
  ]
}
```

> Scope `Resource` tightly. `arn:aws:secretsmanager:*:*:secret:cre-managed/*` means CRE can only touch secrets prefixed `cre-managed/` — anything else in your account is off-limits even if the daemon is compromised.

### Env vars

```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="us-east-1"
# Optional - for STS assumed roles:
# export AWS_SESSION_TOKEN="..."
# Optional - for LocalStack / Tier 2 testing:
# export AWS_ENDPOINT="http://localhost:4566"
```

### Verify

After restart, boot output should show `rotators: env_file, aws_secretsmgr`. If it only shows `env_file`, your AWS env vars aren't being read.

### IRSA / instance profile (no static keys)

If you're running CRE on EC2/EKS, you can drop static keys entirely and use the instance profile. Set `AWS_REGION` and leave `AWS_ACCESS_KEY_ID` unset — current code requires explicit keys, so this is **TODO**: when supported, the SDK chain will pick up IRSA / IMDSv2 automatically.

---

## 7. Wire HashiCorp Vault

### Vault server requirements

- Database secrets engine enabled at `database/`
- A role configured (e.g., `vault write database/roles/myrole ...`)
- A token with `read` on `database/creds/*` and `update` on `sys/leases/revoke`

### Token policy example

`cre-policy.hcl`:

```hcl
path "database/creds/*" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "sys/leases/renew" {
  capabilities = ["update"]
}
```

```bash
vault policy write cre-policy cre-policy.hcl
vault token create -policy=cre-policy -ttl=720h
# capture the .auth.client_token from output
```

### Env vars

```bash
export VAULT_ADDR="https://vault.internal:8200"
export VAULT_TOKEN="hvs.CAESI..."
```

### Verify

Boot output should show `rotators: env_file, ..., vault_dynamic`.

---

## 8. Wire GitHub fine-grained PATs

### The "admin" PAT

You need a fine-grained PAT that has permission to **manage other fine-grained PATs**. This is special:

1. Go to https://github.com/settings/personal-access-tokens
2. Click "Generate new token (fine-grained)"
3. Resource owner: yourself or org
4. Permissions: **Account → Personal access tokens → Read & write**
5. Save the token (`ghp_admin_...`)

> This token has admin power over your other PATs — store it like a root credential. In production, this is a great candidate to itself be managed by `cre` once a year (you rotate the rotator's own credentials).

### Env vars

```bash
export GITHUB_TOKEN="ghp_admin_..."
# Optional - for fake-GitHub Tier 2 testing:
# export GITHUB_API_BASE="http://localhost:7115"
```

### Find your existing PAT IDs

```bash
curl -H "Authorization: Bearer $GITHUB_TOKEN" \
     -H "X-GitHub-Api-Version: 2022-11-28" \
     https://api.github.com/user/personal-access-tokens
```

Use the `id` field from each entry as the `old_pat_id` in your seed SQL.

---

## 9. Wire Telegram (notifications + commands)

### Create the bot

1. Open Telegram, search for `@BotFather`
2. `/newbot`, give it a name + username
3. Save the token (`123456:ABC-DEF...`) — that's `TELEGRAM_TOKEN`

### Find your chat ID

The bot can only message chats you've started a conversation with first.

1. Open your bot in Telegram, send it any message (e.g. `/start`)
2. Visit `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser
3. Find `"chat":{"id":123456789,...}` — that's your chat ID

For group chats: add the bot to the group, send a message, then call `getUpdates` — you'll see a negative chat ID like `-1001234567890`.

### Env vars

```bash
export TELEGRAM_TOKEN="123456:ABC-DEF..."
export TELEGRAM_VIEWER_CHATS="123456789,987654321"   # comma-separated
export TELEGRAM_OPERATOR_CHATS="123456789"           # operators get /rotate, /snooze
```

> Anyone in `OPERATOR_CHATS` can `/rotate` any credential. Anyone in `VIEWER_CHATS` (and operators) can `/status`, `/queue`, `/history`, `/alerts`, `/help`.

### Available commands

| Command | Tier | Purpose |
|---|---|---|
| `/status` | viewer | Quick health snapshot |
| `/queue` | viewer | Active + scheduled rotations |
| `/history <credential-id>` | viewer | Last 10 audit events for one credential |
| `/alerts` | viewer | Pointer to `cre audit verify` |
| `/help` | viewer | Command list |
| `/rotate <credential-id>` | operator | Manually trigger rotation |
| `/snooze <credential-id> 24h` | operator | Defer scheduled rotation (currently a stub) |

### Verify

Boot output: `telegram: enabled`. Open Telegram, send `/status`, you should get a reply within 2 seconds.

---

## 10. Run as a systemd service

### `/etc/systemd/system/cre.service`

```ini
[Unit]
Description=Credential Rotation Enforcer
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=cre
Group=cre
WorkingDirectory=/var/lib/cre
ExecStart=/usr/local/bin/cre run --db=postgres://cre:CHANGEME@localhost:5432/cre_prod
EnvironmentFile=/etc/cre/cre.env
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/cre /etc/myapp   # whatever .env paths you manage
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
```

### `/etc/cre/cre.env` (mode 0600, owner cre:cre)

```
CRE_KEK_HEX=...
CRE_HMAC_KEY_HEX=...
CRE_TICK_SECONDS=60

AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1

VAULT_ADDR=https://vault.internal:8200
VAULT_TOKEN=hvs....

GITHUB_TOKEN=ghp_admin_...

TELEGRAM_TOKEN=123456:...
TELEGRAM_VIEWER_CHATS=123456789
TELEGRAM_OPERATOR_CHATS=123456789
```

### Enable

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cre
sudo systemctl status cre
journalctl -u cre -f      # follow logs
```

---

## 11. Verify and audit

### Live monitoring

```bash
cre watch --db=$DATABASE_URL    # k9s-style live TUI
just tui-demo                    # synthetic 8-second preview (no daemon needed)
```

### One-shot CI gate

```bash
cre check --db=$DATABASE_URL --output=json | jq .
# exit code 0 = no violations, 1 = violations found
```

### Audit chain integrity

```bash
cre audit verify --db=/var/lib/cre/cre.db
# ✓ chain valid: 14,892 entries
```

### Compliance evidence export

```bash
cre export --framework=soc2 --out=/tmp/q1-evidence.zip
unzip -l /tmp/q1-evidence.zip
# audit_log.ndjson, audit_batches.json, control_mapping.json, manifest.json, README.md
```

Hand the ZIP to your auditor. They can verify file checksums against `manifest.json` and recompute the audit hash chain offline.

---

## 12. Key rotation (the KEK / HMAC keys themselves)

The crypto roots are themselves credentials. They have lifetimes too.

### KEK rotation

Annual or on suspected compromise:

1. Generate a new KEK
2. Update `CRE_KEK_HEX` in `/etc/cre/cre.env` (keep the old one in `CRE_KEK_HEX_PREVIOUS` if you wire that)
3. Restart the daemon — it will use the new KEK for new credentials, and the persistence layer will fail to decrypt rows wrapped under the old KEK
4. **Forced rewrap (planned, not yet wired):** `cre crypto rewrap` reads each row, unwraps with `CRE_KEK_HEX_PREVIOUS`, re-wraps with the new KEK. Until that command exists, KEK rotation requires writing a one-off Crystal script.

> KEK rotation without a rewrap path = data loss. Test the rewrap procedure on a non-prod DB before doing this in production.

### HMAC ratchet

The audit log's HMAC key rolls automatically every 1024 entries (configurable). You don't manually rotate it. To force an early rotation, restart the daemon with a new `CRE_HMAC_KEY_HEX` — old entries remain verifiable under their original ratchet generation; new entries chain forward under the new key.

---

## 13. Security checklist before production

- [ ] `CRE_KEK_HEX` and `CRE_HMAC_KEY_HEX` are different random 32-byte values
- [ ] `/etc/cre/cre.env` has mode `0600`, owner `cre:cre`, never committed to Git
- [ ] Database app role demoted to `INSERT, SELECT` on `audit_events`
- [ ] AWS IAM scope is narrow (`Resource: arn:aws:secretsmanager:*:*:secret:cre-managed/*`)
- [ ] Vault token is scoped (no root tokens); rotated periodically itself
- [ ] GitHub admin PAT is also a credential CRE could manage (recursion!)
- [ ] Telegram operator chats list is short and audited (each chat ID is a person)
- [ ] systemd hardening directives applied (`NoNewPrivileges`, `ProtectSystem=strict`, etc.)
- [ ] `cre audit verify` runs as a periodic cron job and pages on failure
- [ ] Compliance bundle export tested end-to-end with a sample auditor walkthrough
- [ ] Backup strategy for the database includes the `audit_events` table (point-in-time recovery preferred over snapshots — protects the chain)

---

## Appendix A: Boot output decoder

When you start `cre run`, expect output like:

```
cre running. PID 4242, tick 60s, db postgres://****:****@db.internal:5432/cre_prod
rotators: env_file, aws_secretsmgr, vault_dynamic, github_pat
telegram: enabled
2026-04-29T15:00:00.000Z   INFO - cre.rotation_worker: registered rotator: env_file
2026-04-29T15:00:00.001Z   INFO - cre.rotation_worker: registered rotator: aws_secretsmgr
2026-04-29T15:00:00.002Z   INFO - cre.rotation_worker: registered rotator: vault_dynamic
2026-04-29T15:00:00.003Z   INFO - cre.rotation_worker: registered rotator: github_pat
2026-04-29T15:00:00.005Z   INFO - cre.engine: engine started
```

`rotators: ...` lists the rotators that successfully wired. If you set `AWS_ACCESS_KEY_ID` but `aws_secretsmgr` is missing, your env var didn't propagate to the daemon — check `systemctl show cre -p Environment` or the EnvironmentFile path.

`telegram: (disabled)` means either `TELEGRAM_TOKEN` is unset or the chat-ID lists are empty. With token + at least one chat, you'll see `telegram: enabled`.

## Appendix B: One-line setup recipes

| Need | Command |
|---|---|
| Tier 1 demo | `just demo` |
| Live TUI preview | `just tui-demo` |
| Full Docker stack | `just demo-full` then `just demo-full-down` |
| Format + lint + test | `just ci` |
| List all recipes | `just` |
