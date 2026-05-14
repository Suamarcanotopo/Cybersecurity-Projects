# Password Vault

## What this is

A small command-line password manager written in Python. You type a master password once, and the tool stores every other password you give it inside a single encrypted file. Later, you ask the tool for "github" or "email" or "bank" and it hands the password back.

The whole thing is roughly 1,400 lines of code spread across five files. No web server, no browser extension, no cloud account. One file on disk, one master password in your head.

```
$ pv init
New master password: ************
Confirm master password: ************
Vault created at /home/you/.password-vault/vault.json

$ pv add github
Username for github: alice
Password for github (hidden): ************
URL (optional, press Enter to skip): https://github.com
Notes (optional, press Enter to skip):
Added entry: github

$ pv get github
╭────────────────── github ──────────────────╮
│ username   alice                           │
│ password   hunter2-but-better              │
│ url        https://github.com              │
│ created    2026-05-13T14:22:10+00:00       │
│ updated    2026-05-13T14:22:10+00:00       │
╰────────────────────────────────────────────╯
```

That's the whole tool. It also has `list`, `delete`, `gen` (generate a strong random password), and `change-password` (rotate the master password).

## Why anyone needs this

The honest answer is "you do." Every site needs a password. Every password should be different. Nobody can remember 200 different passwords, so people reuse one — and the moment any single site gets breached, the attacker tries that same password everywhere else. This is called **credential stuffing** and it is how most account takeovers actually happen in 2025.

A password manager fixes this by giving you exactly one password to remember (the master) while it remembers all the rest. The "every site different" goal becomes achievable because you no longer have to hold them in your head.

**Real-world moments where the security choices in this project matter:**

- The [2013 Adobe breach](https://en.wikipedia.org/wiki/2013_Adobe_breach) leaked 153 million passwords. Adobe had encrypted them with a single key in ECB mode — no salt, no per-record randomness — so identical passwords produced identical ciphertexts. Researchers could see clusters of users who'd all picked `password123` just by looking at the encrypted file. This project's use of a fresh random nonce per save and Argon2id with a per-vault salt is the direct fix for that class of mistake.
- The [2022 LastPass breach](https://blog.lastpass.com/posts/notice-of-recent-security-incident) leaked encrypted vault backups. Vaults with weak master passwords got cracked offline at scale because the attacker had unlimited time. The defense — make each guess expensive — is exactly what Argon2id gives us. Our defaults push each guess to roughly half a second on a modern laptop, which makes a billion-guess attack take ~15 years on the attacker's machine.
- Every CTF challenge or pentest engagement where someone hands you "an encrypted file" and asks "is this safe at rest?" — by the end of this project you'll know what questions to ask (which KDF? which cipher mode? what's the salt situation? is the auth tag verified?).

## What you will learn

**Security ideas:**

- What **symmetric encryption** is — one key encrypts and decrypts. We use [AES-256-GCM](https://en.wikipedia.org/wiki/Galois/Counter_Mode), the same algorithm protecting your bank's HTTPS connection.
- What a **key derivation function (KDF)** does — it turns a human password (short, weak, predictable) into a real cryptographic key (32 bytes of pure unpredictability). We use [Argon2id](https://en.wikipedia.org/wiki/Argon2), the winner of the 2015 Password Hashing Competition and the algorithm OWASP currently recommends for password storage.
- Why **salts** and **nonces** are different things even though they're both "random bytes you store next to the ciphertext."
- What **authenticated encryption** means and why "just encrypted" is not enough — without authentication, an attacker can flip bits in your file in predictable ways without knowing the key.
- The difference between `random` (fine for a dice roll) and `secrets` (the only thing you should ever use when an attacker wants to predict the output).
- Why we **store the KDF parameters in the file** instead of just hard-coding them, and how that decision enables `change-password` to upgrade old vaults to new defaults years later.
- Why writing a file "atomically" (write to `.tmp`, fsync, rename) matters when a power loss could otherwise leave you with zero passwords.

**Python ideas (assuming this is your first time):**

- What a **package** is and what `__init__.py` does for it.
- **Modules** and how `import` actually finds files.
- **Type hints** — `str`, `int`, `bytes`, `list[str]`, `dict[str, Entry]`, `Path | None`. They are not enforced at runtime, but they are the most useful documentation in the language.
- **`@dataclass`** — the shortcut for making record-like classes without writing `__init__` by hand.
- **`Final`** type — telling Python "this value is a constant, never reassign it."
- **Context managers** (`with vault.unlock(...) as v:`) — the cleanest way to say "set up something, use it, tear it down even on errors."
- **Exceptions and custom exception classes** — defining your own error types and catching them by category.
- **Generators**, **dict comprehensions**, **f-strings** — modern Python idioms you'll see everywhere.
- How `pytest` works and why `conftest.py` is special.
- How a CLI built with [Typer](https://typer.tiangolo.com) works — turning a function into a command just by writing its type hints.

**Tools you'll touch:**

- [`uv`](https://github.com/astral-sh/uv) — the modern Python package manager. Like `pip` but ~100× faster.
- [`just`](https://github.com/casey/just) — a command runner. Instead of memorizing long commands, you type `just test` or `just run`.
- [`typer`](https://typer.tiangolo.com) — the CLI framework.
- [`rich`](https://github.com/Textualize/rich) — the library that prints the pretty colored panels and tables.
- [`argon2-cffi`](https://github.com/hynek/argon2-cffi) — the Python binding for the Argon2 reference implementation.
- [`cryptography`](https://cryptography.io) — the Python Cryptographic Authority's library. The gold standard.
- [`pytest`](https://pytest.org) + [`ruff`](https://github.com/astral-sh/ruff) + [`mypy`](https://mypy-lang.org) + [`pylint`](https://pylint.org) — testing and linting.

## What you need before starting

**Knowledge you should have:**

- You've used a terminal at least once (you know what `cd` and `ls` do).
- You've at least seen the words "hash" and "encryption" before. If they're meaningless to you, [01-CONCEPTS.md](./01-CONCEPTS.md) is built to start from zero — read it before the code.
- You can read code, or you're willing to try. Every Python feature gets explained when it first appears.

**Knowledge you do NOT need:**

- Prior Python experience. The whole point of the **foundations** tier is that you start here. This project is the *hardest* of the three foundations projects, though — if anything in here feels too dense, try [hash-identifier](../../hash-identifier/) first.
- Any prior cryptography knowledge. You'll learn what a KDF, a nonce, and an authentication tag are in [01-CONCEPTS.md](./01-CONCEPTS.md). No math beyond counting required — the math lives inside the libraries we call.
- Any prior cybersecurity background.

**Software you need installed:**

- Python 3.13 or newer (3.14 recommended).
- The `uv` tool (the install script will get this for you if you don't have it).
- The `just` tool (also handled by the install script).
- A terminal. Mac: Terminal.app or iTerm2. Linux: whatever your distro shipped. Windows: WSL2 + Ubuntu (strongly recommended over native Windows — the file-locking and fsync code paths are POSIX-flavored).

You do *not* need an IDE — any text editor works. [VS Code](https://code.visualstudio.com) with the Python extension is a fine default.

## Quick start

From inside `PROJECTS/foundations/password-manager/`:

```bash
./install.sh
```

That script installs `uv` and `just` if missing, creates a virtual environment (an isolated Python sandbox just for this project), installs every dependency, and runs the test suite to confirm everything works. Read the output as it goes — don't just close the terminal.

Then create your first vault:

```bash
just run -- init
```

It will ask for a master password, ask you to type it again to confirm, and create an empty vault at `~/.password-vault/vault.json`. The first `init` is slow on purpose — that's Argon2id doing its job, deliberately taking about half a second to derive the key. An attacker who steals your vault file has to pay that same half-second cost for every password they want to guess.

Add an entry:

```bash
just run -- add github
```

It will prompt for the username, the password (input hidden), and optional URL and notes.

Look at the entry:

```bash
just run -- get github
```

You'll see a colored panel with every field. The password is shown in plain text — this is a local CLI tool, the user already trusts their own screen.

Generate a strong random password without touching the vault:

```bash
just run -- gen 32
```

This prints one 32-character password to stdout (nothing else). You can pipe it directly into your clipboard:

```bash
just run -- gen 32 | pbcopy        # macOS
just run -- gen 32 | xclip -sel c  # Linux
```

List every entry name:

```bash
just run -- list
```

Change your master password (the vault gets re-encrypted under a new key):

```bash
just run -- change-password
```

Delete an entry:

```bash
just run -- delete github
```

## Project layout

```
password-manager/
├── src/password_manager/
│   ├── __init__.py        package metadata + re-exports
│   ├── __main__.py        lets `python -m password_manager` work
│   ├── constants.py       every magic number and fixed string
│   ├── crypto.py          Argon2id + AES-256-GCM primitives
│   ├── generator.py       cryptographically secure random passwords
│   ├── vault.py           file format, atomic writes, locking
│   └── main.py            the CLI commands (init, add, get, …)
├── tests/
│   ├── conftest.py        shared pytest fixtures
│   ├── test_crypto.py     round-trip + tamper tests
│   ├── test_generator.py  pool/length/randomness tests
│   └── test_vault.py      end-to-end vault tests
├── install.sh             one-shot setup
├── justfile               shortcuts for run / test / lint / format
├── pyproject.toml         project config + dependencies + linter rules
├── README.md              short pointer to this folder
├── learn/                 you are here
│   ├── 00-OVERVIEW.md     quick start (this file)
│   ├── 01-CONCEPTS.md     KDFs, AES-GCM, salts, nonces, real breaches
│   ├── 02-ARCHITECTURE.md module layout, data flows, file format
│   ├── 03-IMPLEMENTATION.md line-by-line walkthrough
│   └── 04-CHALLENGES.md   extensions if you want to keep going
└── assets/                images, screenshots
```

The split across five source files is the one place this project leaves the "single-file" simplicity of `hash-identifier`. Cryptography wants strict boundaries: the file that talks to `secrets.token_bytes` is a different file from the file that talks to your filesystem, and *both* are different from the file that prints colored panels. If a bug ever creeps in, the small file it lives in is the first place to look.

## Where to go next

1. **[01-CONCEPTS.md](./01-CONCEPTS.md)** — the security ideas. What a KDF is, why we use Argon2id, what AES-GCM actually does for us, why nonces matter, what authenticated encryption means. Read this before the code, even if you think you know it. The framing matters more than the words.
2. **[02-ARCHITECTURE.md](./02-ARCHITECTURE.md)** — how the code is organized into modules, what the vault file looks like on disk, and the step-by-step flow of `init` / `add` / `get` / `change-password`. Diagrams for each.
3. **[03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md)** — read every source file with us, in order, with every Python feature explained as it first appears.
4. **[04-CHALLENGES.md](./04-CHALLENGES.md)** — extension ideas (search, export, TOTP, key-stretching upgrade path) once you've absorbed the rest.

## Common problems

**"command not found: just"**
The install script should set this up, but if it didn't: `curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash`. Then close and reopen your terminal.

**"command not found: uv"**
Same idea: `curl -LsSf https://astral.sh/uv/install.sh | sh`, then reopen your terminal.

**"`pv` is slow on `init`"**
That's the point. Argon2id deliberately takes about half a second per call with the defaults. The user pays it once per session; an attacker pays it on every guess. If it's painfully slow (multiple seconds), your CPU is on the older end — `constants.py` has the three Argon2 tuning knobs you can lower.

**"Wrong master password (or vault file is corrupted)"**
The tool can't tell those two cases apart — that's on purpose, see [01-CONCEPTS.md](./01-CONCEPTS.md). If you're sure you typed the password right, try `ls -la ~/.password-vault/` and check the `vault.json` file size is non-zero.

**"ModuleNotFoundError: No module named 'argon2'"**
You ran `python src/password_manager/main.py` directly instead of going through `just run`. The `just run` recipe uses the virtual environment that has every dependency installed. Either use `just run`, or activate the venv first: `source .venv/bin/activate`, then run `pv` or `python -m password_manager`.

**Tests fail right after install**
Tests should pass on a fresh `./install.sh`. If they don't, check `python --version` — you need 3.13+. On Ubuntu, install a newer Python via [`deadsnakes`](https://launchpad.net/~deadsnakes/+archive/ubuntu/ppa); on Mac use [Homebrew](https://brew.sh).

**"I forgot my master password"**
There is no recovery. That is by design — if there were a way to recover the password, anyone who steals the file would have it too. This is the same trade-off every real password manager makes. Pick something memorable, write down a hint (NOT the password) in a safe physical place, and use `change-password` to rotate it occasionally.
