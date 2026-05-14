# Concepts

This file explains every cryptographic idea the password vault uses, starting from absolute zero. If you've never thought hard about what "encryption" actually is, this is the right place to start. If you already know a KDF from a hash, you can skim — but read the LastPass and Adobe sections, because they are *why* every design choice in the code looks the way it does.

## Table of contents

1. [The problem: storing secrets you'll need later](#1-the-problem-storing-secrets-youll-need-later)
2. [What "encryption" actually is](#2-what-encryption-actually-is)
3. [Symmetric vs asymmetric — we use symmetric](#3-symmetric-vs-asymmetric--we-use-symmetric)
4. [The key problem: where does the key come from?](#4-the-key-problem-where-does-the-key-come-from)
5. [Key derivation functions: making passwords expensive](#5-key-derivation-functions-making-passwords-expensive)
6. [Argon2id specifically, and why](#6-argon2id-specifically-and-why)
7. [Salts: defeating precomputation](#7-salts-defeating-precomputation)
8. [Block ciphers and modes: just "encrypted" is not enough](#8-block-ciphers-and-modes-just-encrypted-is-not-enough)
9. [AES-256-GCM: confidentiality + authenticity in one package](#9-aes-256-gcm-confidentiality--authenticity-in-one-package)
10. [Nonces: the most dangerous thing in this codebase](#10-nonces-the-most-dangerous-thing-in-this-codebase)
11. [random vs secrets: the most common Python-side mistake](#11-random-vs-secrets-the-most-common-python-side-mistake)
12. [Putting it all together: the threat model](#12-putting-it-all-together-the-threat-model)
13. [Real breaches that made these choices the right ones](#13-real-breaches-that-made-these-choices-the-right-ones)

---

## 1. The problem: storing secrets you'll need later

A password manager has a strange job. It needs to:

- Remember your passwords *exactly* (no fuzzy matching — `hunter2` and `Hunter2` are different passwords).
- Refuse to give them up to anyone but you.
- Survive your computer being stolen.
- Survive your computer being seized and forensically imaged.
- Still let *you* in with one short string you can hold in your head.

These goals are in tension. "Remember the password exactly" pulls toward "store it in plain text somewhere." "Don't give it to anyone but you" pulls toward "store nothing at all." The whole rest of this document is about navigating that tension.

The plan that resolves it: **store the passwords scrambled with a key that only the master password can recreate.** If anyone steals the file, all they have is a scrambled blob and a *very expensive* problem to solve. If you type the master password, the key is recreated in seconds and the blob is unscrambled.

That's the entire shape of the project. The rest of this document is how each piece of that plan actually works.

---

## 2. What "encryption" actually is

Encryption is a function. It takes three things in:

- A piece of data (the **plaintext**), like `"my github password is hunter2"`.
- A **key**, which is just a chunk of random bytes — usually 16 or 32 bytes.
- An **algorithm** (a specific procedure for scrambling data using that key).

And it produces one thing out:

- The **ciphertext** — the scrambled version. The same length as the plaintext (plus a tiny overhead, more on that later), but every byte looks like noise.

```
┌──────────────┐
│ "hunter2..." │ ──┐
└──────────────┘   │
                   ▼
            ┌────────────┐    ┌─────────────────────────┐
            │ ENCRYPT()  │ ─► │ "Vh\x91\x03\x7f\xe2..." │
            └────────────┘    └─────────────────────────┘
                   ▲
┌──────────────┐   │
│  32-byte key │ ──┘
└──────────────┘
```

**Decryption** is the same function in reverse. Same key, same algorithm, ciphertext goes in, plaintext comes out.

```
┌─────────────────────────┐
│ "Vh\x91\x03\x7f\xe2..." │ ──┐
└─────────────────────────┘   │
                              ▼
                       ┌────────────┐    ┌──────────────┐
                       │ DECRYPT()  │ ─► │ "hunter2..." │
                       └────────────┘    └──────────────┘
                              ▲
┌──────────────┐              │
│  32-byte key │ ─────────────┘
└──────────────┘
```

If you have the key, decryption is fast and gives you the original. If you have the wrong key — even one bit off — you get garbage out, or (for modern algorithms) the decryption function refuses to run at all and raises an error. We use the second kind.

**Important thing this *isn't*:** encryption is not a one-way operation like a hash. A hash function (SHA-256, MD5, etc.) deliberately throws away information so the original can never be recovered. Encryption keeps every bit — it just shuffles them so you can't read them without the key. The whole point is that the original is recoverable, *but only by you*.

---

## 3. Symmetric vs asymmetric — we use symmetric

There are two big families of encryption.

**Symmetric encryption** uses the *same* key to encrypt and decrypt. Like a locker with one physical key — whoever holds the key can both lock and unlock it. AES is the famous symmetric algorithm. We use it.

**Asymmetric encryption** uses two *different* keys that are mathematically related. One ("public") locks things, the other ("private") unlocks them. You can hand out the public key to the world and they can send you encrypted things only you can read. RSA and elliptic-curve algorithms are the famous asymmetric ones. This is what powers HTTPS at the start of every connection, signs your software updates, and powers SSH login. We do **not** use this.

Why not asymmetric? Because a password manager is a one-person operation. There is no "you encrypt, then someone else decrypts" — *you* encrypt, *you* decrypt. Symmetric is the right tool. Asymmetric algorithms are also massively slower per byte, which matters for the rare cases where they make sense and rules them out for everything else.

---

## 4. The key problem: where does the key come from?

We just said "encryption needs a 32-byte key." Where does a human get 32 random bytes from?

Not from their head. Humans cannot remember 32 random bytes — that's 256 bits of entropy, which is the same as asking someone to memorize a 78-digit number. The best a human can do without writing it down is something like `correct horse battery staple` (~40 bits) or maybe a long sentence (~60 bits). The 256-bit gap is *enormous*.

So we don't ask the human for a key. We ask them for a **password** (which they can remember) and we transform it into a key using a **key derivation function**.

```
┌──────────────────┐      ┌─────────────────┐     ┌─────────────────┐
│ "correct horse   │      │   KEY           │     │ <32 random      │
│  battery staple" │ ───► │   DERIVATION    │ ──► │  bytes>         │
└──────────────────┘      │   FUNCTION      │     └─────────────────┘
                          └─────────────────┘
                                  ▲
┌──────────────────┐              │
│ random salt      │ ─────────────┘
│ (stored in file) │
└──────────────────┘
```

The transformation is deterministic: same password + same salt always produces the same key. That's how we can re-derive the key tomorrow when the user comes back. But the transformation is also **deliberately slow**, which is the trick that makes the whole system safe.

---

## 5. Key derivation functions: making passwords expensive

Imagine an attacker has stolen your vault file. Inside is:

- The salt (16 bytes of public random data).
- The ciphertext (your encrypted passwords).
- The algorithm name and parameters.

The attacker now wants to guess your master password. The naive way: take each candidate password, hash it with the salt, try the result as a key against the ciphertext, see if the result is valid.

If our key derivation were just `SHA-256(password + salt)`, the attacker could do **billions of guesses per second** on a modern GPU. Even a strong-looking password like `Tr0ub4dor&3` would crack in under a minute. That's because SHA-256 was designed for *speed* — it's optimized to verify integrity of huge files in fractions of a second.

**The fix: use a function that is deliberately slow to compute.**

If each guess takes half a second, then a million guesses take 6 days, a billion guesses take 16 years, and a trillion guesses (the universe of "common 12-character passwords") takes 16,000 years. The legitimate user only pays the cost *once* per session — half a second is fine. The attacker pays it on *every* guess, forever.

This is the entire point of a key derivation function (a "KDF"). It's a hash-like operation, but tuned to be expensive — both in CPU time and in memory.

Why both? Because attackers don't use CPUs. They use GPUs and custom hardware called ASICs. A GPU has thousands of small compute cores but very little fast memory per core. So if we use an algorithm that needs a lot of memory (say, 64 megabytes) per guess, the GPU's thousands of cores suddenly can't run in parallel — they'd need a hundred gigabytes of fast memory just to attempt parallel guesses. ASICs face the same problem. **Making the function memory-hungry is what shuts down hardware-based attacks.**

The technical term for this is "memory-hard." Modern KDFs are all memory-hard. Old ones (PBKDF2 from 2000) are CPU-hard but not memory-hard, which is why they've fallen out of favor.

---

## 6. Argon2id specifically, and why

In 2013, the cryptographic community ran the **Password Hashing Competition** — an open contest to pick a new standard KDF. Researchers submitted designs, attacked each other's submissions, and after two years of analysis, the winner was [**Argon2**](https://www.password-hashing.net/argon2-specs.pdf), specifically the variant called **Argon2id**.

Three variants exist:

- **Argon2d** — maximizes resistance to GPU cracking, but is vulnerable to side-channel attacks (where an attacker watches your CPU's memory access timings).
- **Argon2i** — maximizes resistance to side-channel attacks, but is weaker against GPU cracking.
- **Argon2id** — a hybrid that does both, picked as the recommended default.

We use Argon2id. So does the [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html), so do password managers like 1Password and Bitwarden, so does the file encryption tool `age`.

Argon2id has **three tuning knobs** that control how expensive it is:

| Knob              | What it controls                                                  | Our default | Why                                                                                                                          |
| ----------------- | ----------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `time_cost`       | Number of passes over the memory buffer                            | 3           | Strong for interactive use; each extra pass is another factor of slowdown.                                                   |
| `memory_cost`     | KiB of memory used during derivation (1 KiB = 1024 bytes)          | 65536 (64 MiB) | Comfortably above every OWASP profile; defeats GPU/ASIC attackers who lack fast memory per core.                          |
| `parallelism`     | Threads Argon2 may use                                             | 4           | A single user on a modern laptop benefits from parallel speedup. Attacker gets the same speedup, so it's net-neutral on security but improves UX. |

Those numbers live in [`constants.py`](../src/password_manager/constants.py) so they're easy to bump in five years when laptops are faster.

**Important detail:** the parameters are stored *inside the vault file*. If you change the defaults in code, old vaults still open because they remember which parameters they were created with. We'll come back to this — it's also what makes the `change-password` command capable of upgrading old vaults to new parameters.

---

## 7. Salts: defeating precomputation

A **salt** is a piece of random data mixed in with the password before key derivation. It's not secret — we store it in plain text inside the vault file.

Why does it matter?

Imagine you didn't use a salt. Then `derive_key("hunter2") = <some fixed 32 bytes>` — the same on every machine, for every user. An attacker could, *years before any breach*, compute the keys for the top million common passwords and store them in a giant lookup table. Steal a vault → look up the key → unlock the vault. No per-vault work at all.

This precomputation is called a **rainbow table**. It used to be a real attack — there are downloadable rainbow tables for unsalted MD5 covering trillions of common-password hashes.

A salt destroys this attack. Now `derive_key("hunter2", <16 random bytes>) = <different 32 bytes>` for every vault, because every vault has a different salt. The attacker can't precompute anything — they have to do the full Argon2 work *after* they steal the vault file, *per vault they want to attack*.

**Two more uses for salts:**

1. **Per-user uniqueness.** Two users picking the same password (`hunter2` again) get *different* keys, because their salts differ. Useful for password databases at scale, where lots of users do unfortunately pick the same passwords.
2. **Same-user-different-vault uniqueness.** If you have two vaults with the same master password, their ciphertexts are completely different because their salts are different. This isn't an active threat for a single-user password manager, but it's a free benefit of having salts.

Salt size matters less than you'd think. 16 bytes (128 bits) is the standard recommendation. Larger is fine; smaller starts to risk collisions across the global population of vaults.

---

## 8. Block ciphers and modes: just "encrypted" is not enough

Now we have a key. We need to actually encrypt the vault's contents with it. This is where most beginner cryptography projects go wrong, so pay attention.

**AES** is a "block cipher." It encrypts data in fixed-size chunks (16 bytes at a time). Given a 16-byte chunk and a key, it produces another 16-byte chunk that looks random. By itself, AES is just a function from one 16-byte block to another.

But your vault is way more than 16 bytes. So you need a way to chain blocks together. That way is called a **mode of operation**.

The simplest mode is **ECB** ("electronic codebook"): chop the plaintext into 16-byte chunks, encrypt each one independently, concatenate the results. This is wrong. It is famously, illustratively wrong:

```
                ECB-encrypted version
                of an image of Tux the Linux penguin
                (you can still see the penguin)

                ┌────────────────┐
                │ ░░░░░░░░░░░░░░ │
                │ ░░░██████░░░░░ │
                │ ░░██░░░░██░░░░ │      Identical input blocks
                │ ░░░░██████░░░░ │  →   produce identical output
                │ ░░░░░██░░░░░░░ │      blocks, so the image
                │ ░░░░██████░░░░ │      contour leaks through.
                │ ░░░░██░░██░░░░ │
                │ ░░██░░░░░░██░░ │
                │ ░░░░░░░░░░░░░░ │
                └────────────────┘
```

This is why "we use AES" without specifying the mode tells you almost nothing about whether a system is secure.

The next mode up is **CBC** (cipher block chaining), which XORs each block with the previous ciphertext block before encrypting. Better than ECB — identical plaintext blocks now produce different ciphertext blocks. But CBC has *another* problem: it doesn't tell you if the ciphertext was tampered with. An attacker can flip specific bits in the ciphertext to flip *predictable* bits in the decrypted plaintext, even without the key. This is called a **bit-flipping attack** and it's been used against real systems.

The right answer is an **authenticated mode** — one that doesn't just encrypt, but also stamps the output with a tamper-evident seal.

---

## 9. AES-256-GCM: confidentiality + authenticity in one package

**GCM** ("Galois/Counter Mode") is an authenticated mode for AES. It produces two things:

1. The encrypted bytes (same length as the plaintext).
2. A 16-byte **authentication tag** — a small fingerprint of "this exact ciphertext was produced by someone holding this exact key."

```
┌──────────────────┐
│ plaintext bytes  │
│ (vault contents) │
└──────────────────┘
         │
         ▼
┌─────────────────────────────────────────┐
│            AES-256-GCM                  │
│                                         │
│   key  ─┐                               │
│   nonce ├─► [scramble & authenticate]   │
│         │                               │
└─────────┴───────────────────────────────┘
         │                  │
         ▼                  ▼
┌─────────────────┐  ┌─────────────────┐
│ ciphertext      │  │ 16-byte auth    │
│ (same length as │  │ tag             │
│  plaintext)     │  │                 │
└─────────────────┘  └─────────────────┘
```

The library bundles these into a single byte string for you — the "ciphertext" returned by the cryptography library is actually `ciphertext || tag`, with the tag concatenated at the end.

**On decryption**, the cipher checks the tag *before* it gives you the plaintext. If the tag doesn't match (because the key is wrong, the ciphertext was modified, or the nonce is wrong), the cipher raises an error and refuses to produce any plaintext. This is the protection that makes "encrypted with AES-GCM" actually safe.

We use **AES-256**-GCM specifically — the "256" is the key size in bits. AES-128 is also fine, but 256-bit keys are the standard for "I want to never have to think about it again" levels of margin. The performance difference on modern CPUs is negligible because AES has dedicated CPU instructions (AES-NI on Intel/AMD, ARMv8 Crypto Extensions on ARM).

---

## 10. Nonces: the most dangerous thing in this codebase

A **nonce** ("number used once") is a value passed to AES-GCM alongside the key. It must be unique for every encryption performed with the same key. **Reusing a nonce with the same key in GCM is catastrophic** — it leaks plaintext information to anyone watching, and in some cases reveals the authentication key itself.

This is the single sharpest edge of AES-GCM and the reason we are extremely careful about it in [`crypto.py`](../src/password_manager/crypto.py).

What does "leaks plaintext" mean concretely? If you encrypt two different messages M1 and M2 with the same key K and the same nonce N, then `C1 XOR C2 = M1 XOR M2`. An attacker who sees C1 and C2 can compute `M1 XOR M2` without knowing the key. From there, if they can guess any part of M1 or M2, they can recover the corresponding part of the other.

**The fix is mechanical: generate a fresh random 12-byte nonce on every single encryption.** GCM allows up to roughly 2³² (4 billion) encryptions safely under one key with random 12-byte nonces. A single human will never save their vault 4 billion times.

A nonce is *not* a salt. The differences:

| Property        | Salt                           | Nonce                              |
| --------------- | ------------------------------ | ---------------------------------- |
| Used in         | Key derivation (Argon2id)      | Encryption (AES-GCM)               |
| How often       | Once per *vault* (set at init) | Once per *encryption* (every save) |
| Must be unique? | Yes (across all vaults)        | Yes (per key, lifetime)            |
| Secret?         | No                             | No                                 |

Both are random, both go in the file, both are public. But they have different jobs and different lifetimes.

---

## 11. random vs secrets: the most common Python-side mistake

Python has two modules that produce random numbers, and the difference matters more than almost any other API choice in this project:

- [`random`](https://docs.python.org/3/library/random.html) — uses the **Mersenne Twister** algorithm. Fast, statistically uniform, **predictable**. If an attacker sees 624 consecutive outputs, they can reconstruct the internal state and predict every future output forever.
- [`secrets`](https://docs.python.org/3/library/secrets.html) — pulls bytes from the operating system's cryptographic random source (`/dev/urandom` on Linux/Mac, `BCryptGenRandom` on Windows). Unpredictable by design.

Salts and nonces and keys MUST come from `secrets`. Generated passwords MUST come from `secrets`. If you used `random` for any of these, an attacker who saw one output could predict every subsequent password your tool generated — for *every* user, on *every* machine, forever.

This project uses `secrets` everywhere it matters:

- `crypto.generate_salt()` and `crypto.generate_nonce()` → `secrets.token_bytes()`.
- `generator.generate_password()` → `secrets.choice()` and `secrets.randbelow()`.
- The Fisher-Yates shuffle in `generator._secure_shuffle()` → `secrets.randbelow()` instead of `random.shuffle()`.

The rule is simple: **if the output is meant to be hard to predict, use `secrets`. Always.**

---

## 12. Putting it all together: the threat model

A "threat model" is a written-down answer to "who can break this, and how?" Here's ours:

**What we defend against:**

- **Theft of the vault file.** Someone copies `vault.json` from your laptop. Without the master password, all they have is a slow, expensive guessing problem (Argon2id with our defaults: ~0.5 seconds/guess, ~15 years for a billion guesses).
- **Tampering of the vault file.** Someone modifies bytes in `vault.json` to try to cause weird decryption behavior. AES-GCM's authentication tag refuses to decrypt at all.
- **Power loss mid-save.** The atomic-rename + fsync pattern means you always end up with either the OLD vault or the NEW vault, never half of either. Detailed in [02-ARCHITECTURE.md](./02-ARCHITECTURE.md).
- **Two `pv` processes saving at once.** An advisory file lock serializes them, so neither one's save gets silently overwritten.
- **Forgetting your master password (and the file being safe at rest because of it).** This is the entire point.

**What we explicitly do NOT defend against:**

- **A keylogger on your machine.** If something is reading every keystroke, it sees your master password as you type it, and that ends the game. The defense for this lives at a different layer (full-disk encryption, OS-level keylogger detection, hardware security keys). This is not a system-level secure-input project.
- **An attacker watching your screen while the vault is unlocked.** The `pv get` command prints passwords to stdout in plain text. The attacker reading your screen owns the session anyway.
- **A truly compromised OS that can read process memory.** While the vault is unlocked, the decrypted entries and the AES key live in your process's memory. A privileged attacker who can read that memory wins. The `close()` method on `UnlockedVault` is a best-effort wipe, not a guarantee.
- **A weak master password.** Argon2id makes brute force expensive but not impossible. If your master password is `password123`, an attacker willing to wait will eventually crack it. The defense is on you: pick something long.
- **Backups under your control.** The tool writes one file, atomically and durably. Backing it up to somewhere else (a USB stick, Syncthing, etc.) is your job. The encryption means it's safe to back up to places you wouldn't trust with plaintext.

Being honest about what a tool does and does not defend against is a security skill in its own right. Real-world incidents almost always happen at the boundaries of a threat model, not inside it.

---

## 13. Real breaches that made these choices the right ones

**[Adobe 2013](https://www.troyhunt.com/adobe-credentials-and-serious/)** — 153 million records. Adobe encrypted passwords with a single key in **ECB mode** with **no per-record salt**. Result: identical passwords produced identical ciphertexts. Researchers could group users with the same password without knowing the password itself. Combined with password hints stored in plain text, large fractions of the leaked passwords were recovered the same week. Lesson: per-encryption randomness (salts, nonces) and authenticated modes (not ECB) are not optional.

**[LinkedIn 2012](https://en.wikipedia.org/wiki/2012_LinkedIn_hack)** — 6.5 million records. Passwords stored as **unsalted SHA-1**. SHA-1 is fast on a GPU; without salts, the attacker could precompute a rainbow table once and use it forever. 90% of the hashes were cracked within days. Lesson: salts plus a slow KDF (not a fast hash) are the modern minimum.

**[LastPass 2022](https://blog.lastpass.com/posts/notice-of-recent-security-incident)** — encrypted vault backups stolen. The vaults themselves used a real KDF (PBKDF2 with 100,100 iterations at the time of the breach), but PBKDF2 isn't memory-hard, so GPU attacks against weak master passwords have been industrial-scale ever since. Several public reports describe attackers cracking subsets of vaults and using the recovered passwords for cryptocurrency theft. Lesson: a memory-hard KDF (Argon2id, scrypt) is meaningfully stronger than PBKDF2 against modern hardware. We use Argon2id.

**[Heartbleed 2014](https://heartbleed.com)** — a memory-disclosure bug in OpenSSL. Not directly about password storage, but it demonstrated a related principle: the bytes of secret material that live in process memory are real and vulnerable. The discipline of `UnlockedVault.close()` clearing the key and the `with` statement minimizing how long the vault stays unlocked is a downstream of this lesson.

**[Yahoo 2013 / 2016](https://en.wikipedia.org/wiki/Yahoo!_data_breaches)** — 3 billion records (the largest breach in history). Passwords stored as **MD5**. By 2016, MD5 was already 20 years past being considered broken for password storage. Lesson: cryptographic agility (the ability to upgrade hash/KDF choices over time) matters. The reason this project stores the KDF parameters *in the vault file* — instead of hard-coding them — is so old vaults can be upgraded later without forcing users to lose data. The `change-password` command exercises that capability.

---

## Where to go next

Now you know *why* every design choice in the code is what it is. Time to see *how* it's organized.

**[02-ARCHITECTURE.md](./02-ARCHITECTURE.md)** explains how the project is split into modules, what the vault file looks like on disk, and the step-by-step flow of every CLI command.

After that, **[03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md)** walks every source file line-by-line with the Python features explained as they appear.
