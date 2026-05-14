# Architecture

This file is the map. By the end you should be able to draw the project from memory: which file holds what, how the layers depend on each other, what the file on disk actually contains, and the step-by-step flow of every CLI command.

## Table of contents

1. [The five-file layout (and why)](#1-the-five-file-layout-and-why)
2. [Dependency direction — who imports whom](#2-dependency-direction--who-imports-whom)
3. [The vault file format on disk](#3-the-vault-file-format-on-disk)
4. [Flow: `pv init`](#4-flow-pv-init)
5. [Flow: `pv add`](#5-flow-pv-add)
6. [Flow: `pv get` and `pv list`](#6-flow-pv-get-and-pv-list)
7. [Flow: `pv change-password`](#7-flow-pv-change-password)
8. [Flow: `pv gen` (no vault)](#8-flow-pv-gen-no-vault)
9. [Atomic + durable + concurrent-safe writes, drawn out](#9-atomic--durable--concurrent-safe-writes-drawn-out)
10. [Lifecycle of an `UnlockedVault`](#10-lifecycle-of-an-unlockedvault)

---

## 1. The five-file layout (and why)

```
src/password_manager/
├── __init__.py        package entry — re-exports the public API
├── __main__.py        lets `python -m password_manager` work
├── constants.py       every magic number and fixed string
├── crypto.py          Argon2id + AES-256-GCM primitives
├── generator.py       cryptographically secure password generation
├── vault.py           file format, atomic writes, locking, entry CRUD
└── main.py            CLI commands (Typer): init, add, get, list, …
```

Compared to `hash-identifier` (one file, 680 lines), this project is split across five source files (~1,400 lines total). The split isn't decoration — each file has a strict reason to exist:

| File          | Talks to              | Doesn't talk to              | Job                                                                                |
| ------------- | --------------------- | ---------------------------- | ---------------------------------------------------------------------------------- |
| `constants.py` | Nothing               | Anything                     | Single source of truth for numbers, strings, and tunables                          |
| `crypto.py`   | `constants` only      | Filesystem, network, CLI     | Pure cryptography. Bytes in, bytes out. No I/O.                                    |
| `generator.py`| `constants` only      | Filesystem, network, CLI     | Random password generation. Pure function, no I/O.                                  |
| `vault.py`    | `crypto`, `constants` | The terminal, command-line   | File format, atomic writes, file locking, entry add/get/delete                     |
| `main.py`     | All of the above      | —                            | Glue layer between user keyboard and the rest of the code                          |

**Why these boundaries matter:**

- The crypto file calls *no I/O functions*. No file reads, no `print`, no `input`. This means it's trivial to test (just call `encrypt(b"hello", key)`) and impossible to introduce a "let me just print the key for debugging" bug at the wrong layer.
- The vault file knows nothing about the terminal. It raises typed exceptions (`VaultNotFoundError`, `WrongPasswordError`, etc.). The CLI layer catches them and turns them into colored error messages. A future GUI or web frontend could be built on `vault.py` without changing any of it.
- The CLI file knows nothing about cryptography. It calls `UnlockedVault.create(...)` and `vault.add_entry(...)` and `vault.save()`. If we swap Argon2id for something newer next year, `main.py` doesn't change.

This is called **layered architecture**. The lower layers don't import from higher layers. Cryptography is at the bottom; the CLI is at the top.

---

## 2. Dependency direction — who imports whom

```
                    ┌─────────────────────┐
                    │      main.py        │   the CLI (Typer + Rich)
                    │  (commands, glue)   │
                    └──────────┬──────────┘
                               │
                ┌──────────────┼──────────────┐
                ▼              ▼              ▼
        ┌───────────────┐  ┌──────────┐  ┌────────────┐
        │  vault.py     │  │ crypto   │  │ generator  │
        │  (file        │  │   .py    │  │   .py      │
        │   format)     │  │          │  │            │
        └───────┬───────┘  └────┬─────┘  └─────┬──────┘
                │               │              │
                └───────┬───────┴──────┬───────┘
                        │              │
                        ▼              ▼
                  ┌───────────────────────┐
                  │     constants.py      │   no imports of our code
                  │ (numbers + strings)   │
                  └───────────────────────┘
```

**Arrows point in the direction of imports.** `main.py` imports from `vault.py`, `crypto.py`, `generator.py`, and `constants.py`. `vault.py` imports from `crypto.py` and `constants.py`. Nothing imports back the other way. No cycles.

If you ever see an arrow pointing the wrong way (e.g. `crypto.py` importing from `vault.py`), that's a code smell — it usually means a piece of logic landed in the wrong layer. The compiler/linter won't stop you, but the design will start to rot.

---

## 3. The vault file format on disk

The vault is a single JSON file. By default it lives at `~/.password-vault/vault.json` with file permissions `0600` (owner-only).

Here's what the file looks like *roughly* (the base64 fields are abbreviated):

```json
{
  "version": 1,
  "kdf": {
    "name": "argon2id",
    "salt": "X3lkR1d2hcKLwk0PXfQpPg==",
    "time_cost": 3,
    "memory_cost": 65536,
    "parallelism": 4
  },
  "cipher": {
    "name": "aes-256-gcm",
    "nonce": "8tNTPwoq8uTXkpKt",
    "ciphertext": "Yk7eEVTSfA9wL...<lots more base64>...kw=="
  }
}
```

Two layers of JSON live here, and that's important:

**Outer layer (the envelope):** plain JSON containing the metadata needed to *decrypt* the inner layer. Anybody who steals the file can read this — it tells them which KDF and cipher were used, the salt, the nonce. None of this is secret; cryptographic security depends on the *key*, not on hiding the algorithm.

**Inner layer (the ciphertext):** when decrypted, this is *another* JSON document — a dictionary of credential entries:

```json
{
  "github": {
    "username": "alice",
    "password": "hunter2-but-better",
    "url": "https://github.com",
    "notes": "",
    "created_at": "2026-05-13T14:22:10+00:00",
    "updated_at": "2026-05-13T14:22:10+00:00"
  },
  "email": {
    "username": "alice@example.com",
    "password": "another-secret",
    "url": "",
    "notes": "personal Fastmail",
    "created_at": "2026-05-13T14:30:01+00:00",
    "updated_at": "2026-05-14T09:11:42+00:00"
  }
}
```

So: **JSON envelope wrapping encrypted JSON.** Boring, inspectable, portable. Boring is good in security — fewer custom things to get wrong.

**Why JSON specifically?**

- Human-inspectable. You can `cat vault.json` and at least confirm the structure. Useful for debugging.
- Trivially portable. Every language has a JSON parser. If you ever wanted to write a reader for this format in Rust or Go, you'd have it working in an hour.
- Forward-compatible. The `"version": 1` field lets future versions know how to read today's vaults — and lets us refuse to read vaults from a *future* version we don't understand yet.

**Why base64?**

JSON has no way to represent raw bytes. The standard fix is base64: a way to write any binary data as a string of printable ASCII characters (`A-Z`, `a-z`, `0-9`, `+`, `/`, `=`). It bloats the data by ~33% but lets us round-trip bytes through JSON cleanly. Salts, nonces, and ciphertexts are all stored base64-encoded.

---

## 4. Flow: `pv init`

This creates a brand-new empty vault. Trace through what happens step-by-step:

```
user types: `pv init`
   │
   ▼
┌─────────────────────────────────────────────────┐
│ main.init()                                     │
│  - parse --vault flag (or env, or default path) │
│  - exists check: refuse if vault.json exists    │
│  - prompt for master password (twice, confirm)  │
│  - validate: non-empty, >= 8 chars, matches     │
└─────────────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────────────┐
│ UnlockedVault.create(path, master)              │
│  - generate fresh 16-byte salt   (secrets)      │
│  - derive 32-byte key from master + salt        │
│    via Argon2id  (~0.5s on modern laptop)       │
│  - build empty entries dict                     │
│  - call self.save()                             │
└─────────────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────────────┐
│ vault.save()                                    │
│  - serialize entries (empty {}) to JSON         │
│  - generate fresh 12-byte nonce  (secrets)      │
│  - AES-256-GCM encrypt the inner JSON           │
│  - build outer JSON envelope                    │
│  - atomic write to vault.json.tmp               │
│  - fsync data                                   │
│  - os.replace onto vault.json                   │
│  - fsync parent directory                       │
└─────────────────────────────────────────────────┘
   │
   ▼
   `Vault created at ~/.password-vault/vault.json`
```

Two key things to notice:

1. **The salt is generated once, at `create()` time, and never changes for the life of the vault.** Even after `change-password` re-encrypts everything under a new key, the salt itself is regenerated only because the password changed — for a given password, the salt is stable.
2. **The nonce is generated *every save*, never reused.** The slowest path (Argon2id) happens once per session; the second-slowest path (AES-GCM encrypt) happens on every save and uses a fresh nonce each time.

---

## 5. Flow: `pv add`

This unlocks the vault, adds an entry, and saves it back. The Argon2id cost is paid *once* on unlock, then `add` and `save` are both fast.

```
user types: `pv add github`
   │
   ▼
┌─────────────────────────────────────────────────┐
│ main.add()                                      │
│  - prompt for master password                   │
└─────────────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────────────┐
│ UnlockedVault.unlock(path, master)              │
│  - read vault.json from disk                    │
│  - parse JSON envelope                          │
│  - validate version + algorithm names           │
│  - validate Argon2 parameters (sanity floors)   │
│  - extract salt, KDF params, nonce, ciphertext  │
│  - derive_key(master, salt, params)  ← slow     │
│  - AES-256-GCM decrypt(ciphertext, nonce, key)  │
│      ↓ if auth tag fails: raise                 │
│        WrongPasswordError → CLI exits with msg  │
│  - parse inner JSON → entries dict              │
│  - return UnlockedVault(path, salt, params,     │
│                          key, entries)          │
└─────────────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────────────┐
│ main.add() body, inside `with` block            │
│  - prompt for username (visible)                │
│  - if --generate: generate_password(length)     │
│    else: getpass for password (hidden)          │
│  - prompt for url, notes (optional)             │
│  - build Entry(username, password, url, notes,  │
│                created_at=now, updated_at=now)  │
│  - vault.add_entry(name, entry, force=...)      │
│      ↓ if name exists and not force:            │
│        EntryAlreadyExistsError → CLI exits      │
│      ↓ if name is empty or has whitespace:      │
│        ValueError → CLI exits                   │
│  - vault.save()  (atomic, durable, locked)      │
└─────────────────────────────────────────────────┘
   │
   ▼
┌─────────────────────────────────────────────────┐
│ end of `with` block → vault.__exit__()          │
│  - vault.entries = {}                           │
│  - vault.key = bytes(32)  (zero-filled)         │
│ (best-effort wipe; Python bytes are immutable,  │
│  but we drop the references at minimum)         │
└─────────────────────────────────────────────────┘
   │
   ▼
   `Added entry: github`
```

Notice the **two failure modes after decryption**:

- "Wrong password" gets one error message.
- "Vault file is corrupted" gets the *same* error message ("Wrong master password (or vault file is corrupted)").

This is on purpose. GCM authentication failure means one of three things and we can't tell which: wrong password, tampered file, corrupted file. From the user's perspective they're indistinguishable, and *exposing* the difference helps an attacker (who'd know whether their guess was "almost right" vs "definitely wrong key"). We collapse them into one honest message.

---

## 6. Flow: `pv get` and `pv list`

Both follow the same pattern: unlock, read, render, close. The vault is unlocked just long enough to grab the data and is dropped immediately after rendering.

```
pv get github
   │
   ├─► prompt master password
   │
   ├─► UnlockedVault.unlock(...)      (slow once, Argon2id)
   │
   ├─► entry = vault.get_entry("github")
   │         ↓ if not found:
   │           EntryNotFoundError → CLI exits 1
   │
   ├─► console.print(rich.Panel(...))    ← colored panel
   │
   └─► end of `with` → wipe key + entries
```

```
pv list
   │
   ├─► prompt master password
   │
   ├─► UnlockedVault.unlock(...)
   │
   ├─► names = vault.names()         (sorted alphabetically)
   │
   ├─► if not names: print "vault is empty" message
   │
   ├─► build a rich.Table with one row per entry
   │      columns: name, username, updated_at
   │      (passwords are NOT shown in `list`)
   │
   ├─► console.print(table)
   │
   └─► end of `with` → wipe key + entries
```

`list` shows usernames and update times but **not passwords**. The user has to explicitly ask for a password with `get <name>`. This is a small friction that reduces the chance of leaking an entire credential set to anyone watching your terminal.

---

## 7. Flow: `pv change-password`

This is the most cryptographically interesting command. It rotates the master password by:

1. Unlocking the vault with the *old* password (full Argon2id cost).
2. Generating a *fresh salt* and deriving a *new key* from the *new* password.
3. Saving the vault — `save()` will encrypt the existing entries under the new key, with a fresh nonce.

```
pv change-password
   │
   ├─► prompt: "Current master password: "
   │
   ├─► UnlockedVault.unlock(path, current_password)
   │     ↓ if wrong: WrongPasswordError → exit 1
   │
   ├─► prompt: "New master password: " (twice, confirm)
   │     ↓ validate: non-empty, >= 8 chars, matches
   │
   ├─► vault.change_master_password(new_password)
   │     - new_salt = secrets.token_bytes(16)
   │     - new_key = derive_key(new, new_salt, defaults)
   │     - self.salt = new_salt
   │     - self.kdf_parameters = defaults()
   │     - self.key = new_key
   │     (only mutates in-memory state — disk untouched)
   │
   ├─► vault.save()
   │     - serializes the SAME entries dict (preserved)
   │     - generates a NEW nonce
   │     - encrypts under the NEW key
   │     - atomic write replaces the old file
   │
   └─► "Master password changed. Vault re-encrypted at <path>"
```

**Why this is interesting:** the vault file stores the KDF parameters and salt next to the ciphertext. That's *exactly* why this operation is possible. If the KDF params lived only in the code, then "change my password" would have no way to also "upgrade my Argon2 parameters from last year's defaults to this year's." Putting them in the file makes the upgrade path possible. The `kdf_parameters` argument on `change_master_password` is the hook for it.

**Crash safety:** if the process dies between mutating the in-memory state and the atomic save completing, the *file on disk* still has the old salt and old ciphertext — fully readable with the old password. The new key only "wins" after `os.replace` lands. This is the entire reason atomic writes matter for password managers: a botched rotation must never lock you out.

---

## 8. Flow: `pv gen` (no vault)

The simplest command. Doesn't touch the vault at all. Doesn't prompt for the master password. Just generates a strong random password and prints it.

```
pv gen 32
   │
   ▼
generate_password(length=32,
                  use_lowercase=True,
                  use_uppercase=True,
                  use_digits=True,
                  use_symbols=True)
   │
   ├─► length >= MIN (8)?
   ├─► at least one pool enabled?
   ├─► length >= number of enabled pools?
   │      (need to fit one char from each)
   │
   ├─► required = [secrets.choice(pool) for pool in pools]
   │      one char guaranteed from each enabled pool
   │
   ├─► fill = [secrets.choice(combined) for _ in range(length - len(required))]
   │
   ├─► chars = required + fill
   │
   ├─► _secure_shuffle(chars)
   │      Fisher-Yates with secrets.randbelow
   │      (NOT random.shuffle — predictable)
   │
   └─► return "".join(chars)
```

The output goes to stdout via plain `print()` (not the rich console), so it's pipe-friendly:

```bash
pv gen 32 | pbcopy
PASSWORD=$(pv gen 32)
```

This is the only command that uses `print` instead of `console.print`. The reason is exactly piping: we don't want rich's color escape codes inside the password that gets piped to `pbcopy`.

---

## 9. Atomic + durable + concurrent-safe writes, drawn out

The `save()` method does more work than you'd guess. The "just write the file" version of this would be one line; ours is a few dozen. Here's why each piece is there.

### What can go wrong with the naive approach

```python
# DON'T DO THIS
path.write_bytes(envelope_bytes)
```

This has three problems, all of which we've seen happen in real systems:

1. **Crash mid-write → corrupt file.** If the process dies after writing 4096 bytes of a 6000-byte file, the file is half-written. Next time the user tries to unlock, JSON parsing fails and they think their vault is destroyed.
2. **Power loss → 0-byte file (or worse).** Even if the process completes, the bytes live in the kernel's page cache. The OS will write them to disk *eventually*, but a power loss between write and disk-write means the file appears to exist but contains nothing.
3. **Two `pv` instances racing.** User runs `pv add github` in one terminal and `pv add email` in another simultaneously. Both unlock the vault (slow), both add their entry, both save. Whichever saves *second* loses the other's entry — silently. No error.

### How we fix each one

```
        ┌──────────────────────────────────────────────┐
        │ 1. acquire advisory flock on vault.json.lock │
        │    (POSIX systems — Windows skips this)      │
        └──────────────────┬───────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────┐
        │ 2. os.open(vault.json.tmp, …, mode=0600)     │
        │    file created world-unreadable from the    │
        │    very first syscall (no chmod race)        │
        └──────────────────┬───────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────┐
        │ 3. os.write(fd, envelope_bytes)              │
        └──────────────────┬───────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────┐
        │ 4. os.fsync(fd)                              │
        │    forces kernel page cache → disk.          │
        │    without this, "we wrote it" is a story    │
        │    the page cache tells; a power loss erases │
        │    it.                                       │
        └──────────────────┬───────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────┐
        │ 5. os.close(fd)                              │
        └──────────────────┬───────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────┐
        │ 6. os.replace(vault.json.tmp, vault.json)    │
        │    atomic rename. after this instant,        │
        │    readers see EITHER the old file OR the    │
        │    new file. never half of either.           │
        └──────────────────┬───────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────┐
        │ 7. fsync the parent directory (POSIX)        │
        │    so the rename itself survives power loss. │
        │    without this, an OS crash right after the │
        │    rename can revert the directory entry.    │
        └──────────────────┬───────────────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────────────┐
        │ 8. release advisory flock                    │
        └──────────────────────────────────────────────┘
```

Each step plugs one hole:

| Step | Plugs                                  |
| ---- | -------------------------------------- |
| 1, 8 | Two `pv` processes racing              |
| 2    | Brief window where tmp file is world-readable |
| 4    | "Power loss right after write" loses data |
| 6    | "Crash mid-write" corrupts the live file |
| 7    | "Power loss right after rename" reverts |

The advisory lock is interesting: it's not enforced by the OS, only by code that opts in. A process that ignores `flock` can still write the file. But *every* `save()` in our code opts in, so two `pv` invocations can't race against each other. An external editor (vim, `sed`) doesn't lock, but a user editing the vault file by hand has already left the tool's contract.

Windows doesn't have `fcntl.flock` or directory `fsync`, so we skip both there. NTFS gives us atomic `os.replace` regardless. The trade-off is: on Windows we lose cross-process serialization (rare edge case for a single-user tool) and we lose the absolute-guarantee directory durability (NTFS journaling covers most cases).

---

## 10. Lifecycle of an `UnlockedVault`

An `UnlockedVault` is a Python object that holds:

- The path to the vault file on disk.
- The 16-byte salt.
- The Argon2 parameters that were used.
- The 32-byte AES key (sensitive!).
- The decrypted entries (also sensitive! they contain plaintext passwords).

Holding the key in memory means subsequent operations (add, get, delete, save) don't have to re-derive it — they'd otherwise pay the Argon2 cost on every save. But it also means we want a clear "I'm done with this" signal.

Python's `with` statement (a "context manager") is exactly that signal:

```python
with UnlockedVault.unlock(path, master) as vault:
    vault.add_entry("github", entry)
    vault.save()
# at this point, vault.__exit__ has been called
# vault.entries is now {}
# vault.key is now b"\x00" * 32
```

`__enter__` runs when the block starts. `__exit__` runs when the block ends — *whether normally or by exception*. So even if `vault.save()` raises, the cleanup still happens.

The cleanup itself (`vault.close()`) replaces the entries dict with `{}` and the key with 32 zero bytes. This is a **best-effort** wipe. Python's `bytes` objects are immutable, so the original key bytes might still live in memory until the garbage collector runs. True wipe-on-free in Python requires `bytearray` plus `ctypes` tricks that this teaching project deliberately avoids — the discipline of "drop secrets explicitly when done" is the more important habit.

```
       ┌────────────────────────────────────────────┐
       │  UnlockedVault.unlock(path, master)        │
       │  ─ slow: Argon2id derives 32-byte key      │
       │  ─ AES-GCM decrypts ciphertext             │
       │  ─ returns instance: { path, salt, params, │
       │                       key, entries }       │
       └────────────────────────────────────────────┘
                              │
                              ▼
       ┌────────────────────────────────────────────┐
       │  __enter__ → returns self                  │
       └────────────────────────────────────────────┘
                              │
                              ▼
       ┌────────────────────────────────────────────┐
       │  body of `with` block                      │
       │  ─ get_entry, add_entry, delete_entry      │
       │  ─ save() (fast: key already in memory,    │
       │            just AES-GCM + atomic write)    │
       └────────────────────────────────────────────┘
                              │
                              ▼
       ┌────────────────────────────────────────────┐
       │  __exit__ → close()                        │
       │  ─ self.entries = {}                       │
       │  ─ self.key = b"\x00" * 32                 │
       │  (best-effort wipe; Python bytes are       │
       │   immutable, GC may still hold copies)     │
       └────────────────────────────────────────────┘
```

This is the same pattern Python's `open()` uses (`with open("x.txt") as f:`). The vault is just a more security-sensitive resource than a file handle.

---

## Where to go next

You now have the shape of the project in your head: which file does what, what the file on disk looks like, what each command does step-by-step.

**[03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md)** walks every source file line-by-line. Open `crypto.py`, `vault.py`, and `main.py` in a second window and read along.
