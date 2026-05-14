# Challenges

You've read the whole project. You understand why every line is what it is. Now what?

The honest answer is: **build something on top of it.** The fastest way to actually learn what you just read is to extend it. The challenges below are ordered roughly easy → hard. Pick one that interests you, sketch what you'd change, and try.

If you get stuck, the relevant pieces of the existing code are linked. If you finish one and want to share it, fork the repo and open a PR — the foundations tier is meant to be a stepping stone, not a finished thing.

## A note on scope

Don't try to do all of these. Don't even try to do five. Pick *one*, do it well, and stop. The point isn't to add features — it's to internalize the existing code by interacting with it.

For each challenge below, you'll find:

- **What** — a sentence or two describing the feature.
- **Why it's interesting** — what you'll learn from building it.
- **Where to start** — which file(s) you'd touch.
- **Watch out for** — the security or correctness traps that catch beginners.

---

## Tier 1 — small features (~30 minutes each)

### 1. Add a `search` command

**What:** `pv search <substring>` lists every entry name that contains the substring (case-insensitive). Like `pv list`, but filtered.

**Why it's interesting:** Easy to do, but forces you to read `main.py` and `vault.py` carefully and find the right seam to add a new command. Good "first PR" warmup.

**Where to start:** Copy the `list_entries` command in `main.py`. Filter `unlocked.names()` before rendering the table.

**Watch out for:**
- Case-insensitive comparison: use `name.lower()` and `query.lower()`.
- Empty search query should be rejected, not return "every entry."

### 2. Add a `count` command

**What:** `pv count` prints just the number of entries. Useful for shell scripts.

**Why it's interesting:** Smallest possible new command. Forces you to think about output format (number + newline, no decoration) so it can be piped: `if [ "$(pv count)" -eq 0 ]; then ...`.

**Where to start:** Copy `gen` — it's the simplest existing command. Read entries, print `len(unlocked.entries)`.

**Watch out for:**
- Use `print()`, not `console.print()`, so the output is pipe-friendly.
- An empty vault still prints `0`, not "vault is empty."

### 3. Show a "last used" timestamp

**What:** Add a `last_used_at` field to `Entry`. The `get` command updates it (and saves the vault).

**Why it's interesting:** You'll touch every layer — the `Entry` dataclass, its `from_dict`/`to_dict`, the save path, and `get` in `main.py`. Good way to see the architecture in motion.

**Where to start:** Add the field with `field(default_factory=lambda: "")` so old vaults open without it. Bump the implicit field count in `from_dict`.

**Watch out for:**
- Old vaults won't have the field — handle the missing-key case the same way `created_at` and `updated_at` do.
- `get` now mutates the vault → must call `save()` before the `with` block ends.
- This changes the threat model: an attacker who steals the vault now learns *which entry you used most recently*. Document the trade-off.

### 4. Hide passwords in `get` unless `--show` is passed

**What:** `pv get github` shows everything except the password (`••••••••`). `pv get github --show` shows the real password.

**Why it's interesting:** Tiny UX change, but it's the kind of feature real password managers ship for "in a meeting screen-sharing" moments.

**Where to start:** Add a `--show / -s` flag to the `get` command. In `_render_entry`, branch on the flag.

**Watch out for:**
- Default to hidden, opt-in to visible — secure by default.
- Bullet character `•` may not render in every terminal — provide a fallback.

---

## Tier 2 — medium features (a few hours each)

### 5. Implement `pv export` and `pv import`

**What:** `pv export <path>` writes every entry to a plain-text JSON file (after prompting for the master password and a strong "ARE YOU SURE" warning). `pv import <path>` does the reverse.

**Why it's interesting:** This is real, useful, and dangerous. Real because every password manager needs migration in and out. Useful because users die, lose phones, switch tools. Dangerous because plaintext credentials on disk is exactly what we built this tool to avoid.

**Where to start:** Add two commands to `main.py`. Export serializes `unlocked.entries` and writes a JSON file with mode 0600. Import reads JSON, validates structure, calls `add_entry` for each.

**Watch out for:**
- The export file is plaintext. Print a giant red warning before writing.
- Default the export path to `./pv-export.json`, not the user's home directory — make them think about where it lives.
- Import should handle "entry already exists" gracefully — either ask, or take a `--force` flag, or skip.
- Validate the imported JSON the same way `Entry.from_dict` validates — don't trust the file structure.
- An exported file with weak filesystem permissions is a real foot-gun. Set mode 0600 explicitly with `os.open` (same trick `_atomic_write` uses).

### 6. Add password strength scoring

**What:** When a user runs `pv add`, show them a strength score (weak/fair/strong/excellent) before saving. Use a library like [`zxcvbn-python`](https://github.com/dwolfhub/zxcvbn-python).

**Why it's interesting:** Practical UX feature. Forces you to add a new dependency (touching `pyproject.toml` and `uv.lock`) and understand the difference between "looks random to a human" and "would survive an offline guessing attack."

**Where to start:** Add `zxcvbn` to `pyproject.toml`. Call it on the entered password. Map the 0-4 score to a color and label. Allow the user to proceed anyway.

**Watch out for:**
- Don't *block* the user from saving a weak password — they may have a good reason. Warn and ask.
- The score should be displayed before the password is permanent — if you wait until after `save()`, the user has to delete and re-add to try again.

### 7. Add a `pv copy <name>` command

**What:** Copy a password to the system clipboard without printing it. Use [`pyperclip`](https://github.com/asweigart/pyperclip).

**Why it's interesting:** Real password managers do this. Forces you to think about platform differences (clipboard APIs differ on Linux/Mac/Windows) and the security trade-off of having credentials in the clipboard.

**Where to start:** Add `pyperclip` to dependencies. New command that unlocks the vault, fetches the entry, copies its password, and prints a confirmation (NOT the password).

**Watch out for:**
- On Linux you need `xclip` or `wl-clipboard` installed at the system level — document this.
- Clipboard contents persist until something else overwrites them. Bonus challenge: spawn a background thread that clears the clipboard after 30 seconds.
- Pyperclip on remote SSH sessions doesn't work — handle the import-time failure with a clear error.

### 8. Add a `--verify` flag to `init`

**What:** After creating a vault, immediately try to unlock it with the same password. If unlock fails, panic — something is corrupt.

**Why it's interesting:** Defense in depth. The save → re-unlock cycle would have caught some classes of bugs during development. Builds the habit of "test the read path on every write" that file-format projects benefit from.

**Where to start:** Add a `--verify / -V` flag to `init`. After `UnlockedVault.create()` returns, call `UnlockedVault.unlock()` with the same password. Print a green check or a red panic.

**Watch out for:**
- The verify call costs another full Argon2 derivation (~0.5s). Make it opt-in, not default.
- If the verify *fails*, something is very wrong — refuse to leave the new vault in place. Delete it.

---

## Tier 3 — bigger features (a weekend each)

### 9. Add TOTP (time-based one-time passwords)

**What:** Some sites use TOTP for 2FA. Currently you store the secret somewhere else (Google Authenticator, Authy). Add a TOTP secret field to `Entry`, and a `pv totp <name>` command that prints the current 6-digit code.

**Why it's interesting:** You'll learn what TOTP actually is (it's [RFC 6238](https://datatracker.ietf.org/doc/html/rfc6238) and surprisingly simple — HMAC-SHA1 of the current 30-second window). The Python library `pyotp` does it in two lines, but writing the core yourself is a 30-line exercise.

**Where to start:** Add `pyotp` to dependencies. Add an optional `totp_secret` field to `Entry`. Add the command in `main.py`.

**Watch out for:**
- The TOTP secret is at least as sensitive as the password. It belongs *inside* the encrypted vault, not in a sidecar file.
- Time skew matters. Print "this code is valid for X more seconds" so the user doesn't try to use one that's about to roll over.
- Importing TOTP secrets from QR codes is its own project — don't try to do that here.

### 10. Make the KDF cost upgrade transparent

**What:** When a user unlocks a vault whose Argon2 parameters are below the current code's defaults, *automatically* re-derive the key with the new defaults and save — same password, stronger derivation. Print a message: "Vault parameters upgraded to current defaults."

**Why it's interesting:** This is what real password managers do. It's why we store the KDF parameters in the file. Forces you to fully understand the `change_master_password` flow and to think about UX for "long-running operation users didn't ask for."

**Where to start:** Inside `UnlockedVault.unlock`, after successful decryption, compare `kdf_parameters` to `KdfParameters.defaults()`. If they differ, do an in-place change (call something like `change_master_password(same_password, new_kdf_parameters=...)`) and save.

**Watch out for:**
- Pay the new Argon2 cost only once, not twice. Refactor `change_master_password` so it can also "upgrade in place" without rotating the password.
- The user will see two sequential ~0.5-second pauses. Tell them why with a message before the second one.
- Add a `--no-auto-upgrade` flag for users who don't want this.

### 11. Implement a `pv backup` command with versioned snapshots

**What:** `pv backup` writes a copy of the current vault to `~/.password-vault/backups/vault-YYYY-MM-DD-HHMMSS.json` and keeps the last N backups. Add a `pv restore <timestamp>` command that overwrites the live vault from a backup.

**Why it's interesting:** Real systems need backups, but backups are *also* a security surface — they're more files an attacker can steal. Forces you to think about: how many to keep, where to store, whether to also encrypt the backup index, what happens on restore (you want atomic semantics).

**Where to start:** Add the two commands. Use the existing atomic-write pattern (don't write the backup with `Path.write_bytes`; use `_atomic_write`). Use the existing file-lock pattern.

**Watch out for:**
- Backups are full copies of the encrypted file — they're encrypted, so they're "safe to lose to disk forensics" *to the same extent* as the live vault is, but no more.
- Pruning old backups requires care — don't delete the file that's currently being read by another `pv` process. Use the same advisory lock.
- "Restore from backup N" needs to validate that backup N is a *real* vault (parse the envelope, check version) before overwriting the live file.

### 12. Add a web UI in a separate `pv web` command

**What:** A local-only web server (`localhost:8080`) that serves a simple UI for browsing the vault. Auto-shuts down after 10 minutes of inactivity.

**Why it's interesting:** Forces you to think about *every* security trade-off you didn't have to think about with a CLI. Master password handling in a browser, CSRF, XSS, session timeout, HTTPS-or-not on localhost, what to do when a second tab opens.

**Where to start:** Use [`starlette`](https://www.starlette.io) or [`fastapi`](https://fastapi.tiangolo.com) for the server. Render entries with Jinja2 templates. Don't use cookies — use a single in-memory session that auto-expires.

**Watch out for:**
- This is genuinely harder than it looks. Real password managers' web UIs are full-time engineering jobs. The point of *this* version is to learn what the trade-offs are, not to ship a production tool.
- The browser is now a part of your threat model. Browser extensions can read DOM. Other tabs can navigate to your `localhost:8080`. Same-origin policy is your only friend.
- Logging — Starlette/FastAPI will helpfully log every request. Make sure the access log doesn't include the master password (it won't, if you do form POST correctly, but check).

---

## Tier 4 — research-flavored projects

These don't have a clean "build this exact feature" shape. They're directions to push the project in if you've absorbed everything and want to keep going.

### 13. Audit a real password manager's threat model

Pick a real, open-source password manager: [Bitwarden](https://github.com/bitwarden), [KeePassXC](https://github.com/keepassxreboot/keepassxc), [pass](https://www.passwordstore.org). Read its docs and source for the equivalent pieces of *this* project: how does it derive keys, how does it store the file, how does it handle master password rotation? Write up a comparison.

You'll learn that real password managers make different trade-offs — sometimes for good reasons, sometimes for legacy reasons. The exercise of identifying *which is which* is the kind of analysis security engineers do for a living.

### 14. Write a vault-format reader in another language

The vault format is documented in [02-ARCHITECTURE.md §3](./02-ARCHITECTURE.md#3-the-vault-file-format-on-disk) and the JSON keys are constants in `constants.py`. Write a read-only client in Rust, Go, or whatever you're learning next. You'll find the libraries to use (`argon2`, `aes-gcm`), match versions/parameters, and validate the cross-language round trip.

This is a really good exercise. It demonstrates *why* we wrote the format down — and probably exposes places where the format underspecifies something (which is the kind of thing real-world interop projects find all the time).

### 15. Threat-model a deliberate weakness

Pick one assumption from the threat model section of [01-CONCEPTS.md §12](./01-CONCEPTS.md#12-putting-it-all-together-the-threat-model). Try to defeat it.

Examples:
- "We don't defend against a keylogger." Try writing a Python keylogger that watches the `pv` process's stdin (you'll find it's surprisingly hard because `getpass` reads from the terminal device, not stdin). Then try writing one that hooks at the OS level on Linux — what permissions does it need?
- "We don't truly wipe the key from memory." Use a memory-debugging tool (`gcore` + `strings`) on a running `pv` process to find the AES key. Then design what would *actually* protect against this and explain why we didn't implement it.

The goal isn't to weaponize anything. It's to viscerally feel the difference between "we don't claim to defend against X" and "we couldn't even if we wanted to."

---

## What to read next

If you got through 03-IMPLEMENTATION and you're done with this project:

- **The [intermediate tier](../../../intermediate/)** — projects that involve web servers, databases, and multiple files. The jump from this project to those is much smaller now than it was before you started.
- **The [advanced tier](../../../advanced/)** — projects that involve real distributed systems and serious security primitives.
- **[Crypto 101](https://www.crypto101.io)** by Laurens Van Houtven — a free book that goes deeper on every cryptographic idea in this project. Especially recommended if you found §8-9 in [01-CONCEPTS.md](./01-CONCEPTS.md) interesting and want the full background.
- **[Cryptography Engineering](https://www.schneier.com/books/cryptography-engineering/)** by Ferguson, Schneier, and Kohno — the textbook. Heavier than Crypto 101, but the definitive reference for "how cryptographic systems actually fail in practice."

You finished the hardest project in the foundations tier. You now know more about real-world password storage than the engineers responsible for [most of the breaches we cited](./01-CONCEPTS.md#13-real-breaches-that-made-these-choices-the-right-ones). That's worth pausing to appreciate.
