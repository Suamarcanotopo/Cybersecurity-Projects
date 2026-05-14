# Core Security Concepts

This document explains the security concepts behind hash cracking. These aren't just definitions. We'll dig into how attacks actually work, why certain defenses exist, and what real breaches teach us about password storage.

## Cryptographic Hash Functions

### What They Are

A hash function takes input of any length and produces a fixed-length output (the digest). The same input always produces the same output, but you can't work backwards from the output to recover the input. This is a one-way transformation, not encryption.

```
"password"  → SHA256 → 5e884898da28047151d0e56f8dc...  (always this, every time)
"password1" → SHA256 → 0b14d501a594442a01c6859541bc...  (completely different)
"Password"  → SHA256 → 22ee405817c14cbf9d3c2b92b87c...  (completely different again)
```

Three properties make hash functions useful for password storage:

1. **Deterministic**: Same input, same output. The server can verify your password by hashing what you type and comparing to the stored hash
2. **Pre-image resistant**: Given a hash, you can't compute the input that produced it. Even if an attacker steals the hash database, they don't have plaintext passwords
3. **Avalanche effect**: Changing one bit of input changes roughly half the output bits. "password" and "Password" produce completely unrelated hashes

### Algorithms This Tool Supports

| Algorithm | Digest Length | Status | Real World Usage |
|-----------|--------------|--------|-----------------|
| MD5 | 128 bits (32 hex chars) | Broken since 2004 | Still found in legacy systems, WordPress before 4.x |
| SHA1 | 160 bits (40 hex chars) | Broken since 2017 | LinkedIn breach (2012), Git (transitioning away) |
| SHA256 | 256 bits (64 hex chars) | Secure | Bitcoin, TLS certificates, many web frameworks |
| SHA512 | 512 bits (128 hex chars) | Secure | Linux /etc/shadow default, some enterprise systems |

"Broken" for MD5 and SHA1 means researchers can generate collisions (two different inputs producing the same hash). For password cracking, the bigger problem is speed: these were designed to be fast, which is exactly what you don't want for password hashing.

### What Hash Functions Are NOT

Hash functions are not encryption. Encryption is reversible with a key. Hashing is not reversible at all. You don't "decrypt" a hash. You guess inputs, hash them, and check if the output matches. That's cracking.

## Dictionary Attacks

### How They Work

A dictionary attack tries every word from a list of known passwords. The attacker hashes each word and compares it to the target hash:

```
Target: 5e884898da28047151d0e56f8dc6292773603d0d...

Hash("123456")   → "e10adc..."  ≠ target
Hash("password") → "5e8848..."  = target  ← found it
```

This works because people choose predictable passwords. The RockYou breach in 2009 leaked 32 million plaintext passwords, and the top 10 were:

```
1. 123456        6. monkey
2. 12345         7. 1234567
3. 123456789     8. letmein
4. password      9. trustno1
5. iloveyou     10. dragon
```

These lists get reused across every cracking tool. A 14 million word dictionary takes seconds to exhaust against a fast hash like SHA256 on modern hardware.

### Why They're So Effective

HaveIBeenPwned tracks over 613 million passwords from real breaches. If your password has ever appeared in any breach, it's in a cracking dictionary. Password reuse makes this worse: the password you use for a throwaway forum might end up in a dictionary used to crack your email account.

## Brute Force Attacks

### How They Work

Brute force generates every possible combination of characters up to a maximum length:

```
Length 1: a, b, c, ..., z                              (26 combinations)
Length 2: aa, ab, ac, ..., zz                           (676 combinations)
Length 3: aaa, aab, ..., zzz                            (17,576 combinations)
Length 4: aaaa, ..., zzzz                               (456,976 combinations)
...
Length 8: aaaaaaaa, ..., zzzzzzzz                       (208 billion combinations)
```

The keyspace grows exponentially. Add uppercase letters and the base goes from 26 to 52. Add digits and it's 62. Add special characters and it's 95. An 8-character password using all character types has 95^8 = 6.6 quadrillion combinations.

### The Math of Feasibility

At 3 million SHA256 hashes per second (what this tool achieves on CPU):

| Password | Character Set | Combinations | Time |
|----------|--------------|-------------|------|
| 4 chars | lowercase | 456K | 0.15 seconds |
| 6 chars | lowercase | 308M | 1.7 minutes |
| 6 chars | lower + digits | 2.2B | 12 minutes |
| 8 chars | lowercase | 208B | 19 hours |
| 8 chars | all printable | 6.6Q | 70,000 years |

GPU cracking tools like hashcat achieve 3 billion per second (1000x faster), but even then 8 characters with full character sets takes 25 days. This is why password length matters more than complexity.

## Rule-Based Mutations

### How They Work

Humans are predictable. When forced to add a capital letter, most people capitalize the first letter. When forced to add a number, they append it. When forced to add a special character, they use `!` or `@`. Rule based attacks exploit these patterns:

| Rule | Input | Output |
|------|-------|--------|
| Capitalize first | password | Password |
| Uppercase all | password | PASSWORD |
| Leet substitution | password | p@$$w0rd |
| Append digits 0-999 | password | password123 |
| Reverse | password | drowssap |
| Toggle case | password | PASSWORD |

This turns a 14 million word dictionary into billions of candidates. The combination of `capitalize + leet + append digits` transforms `password` into `P@$$w0rd123`, which satisfies every password policy ever written and still cracks in milliseconds.

### Why Complexity Requirements Don't Work

The 2021 Specops analysis of 800 million breached passwords found that 83% met standard complexity requirements (8+ characters, uppercase, lowercase, number, special character). The most common patterns:

```
[Word][Number]        → Password1
[Word][Number][!]     → Password1!
[Season][Year]        → Summer2024
[Name][Birthday]      → Michael1990!
```

Password managers generating random strings like `x7$kQ2!mR9pL` are the actual defense. No dictionary contains that, and brute forcing 12 random characters from the full printable set is computationally infeasible.

## Password Salting

### What It Is

A salt is a random string stored alongside the password hash. Before hashing, the salt is prepended or appended to the password:

```
Without salt:
  User A: SHA256("password")       → 5e884898da...
  User B: SHA256("password")       → 5e884898da...  (identical!)

With salt:
  User A: SHA256("x9f2" + "password") → a1b2c3d4...
  User B: SHA256("k7m1" + "password") → 9z8y7x6w...  (completely different)
```

The salt is not secret. It's stored in plaintext right next to the hash in the database. Its only job is to make each user's hash unique, even if they use the same password.

### What Salt Prevents

**Rainbow tables** are precomputed lookup tables mapping hashes to passwords. Without salt, you compute SHA256("password") once and it matches every user who chose "password". A rainbow table for SHA256 covering common passwords might be 100GB, but it cracks millions of hashes instantly.

Salt makes rainbow tables useless. Each user has a different salt, so you'd need a separate rainbow table for every possible salt value. With a 16-byte salt, that's 2^128 possible tables. Not happening.

**Mass cracking** is also defeated. Without salt, if you crack one hash, you've cracked every user with that password. With salt, you crack one user at a time because each hash is computed differently.

### What Salt Does NOT Prevent

Salt does not slow down targeted cracking. If an attacker wants to crack one specific user's hash, they know the salt (it's in the database) and just prepend it to every guess. The cracking speed is identical. Our `--salt` flag demonstrates this exact attack.

### Real World Salt Failures

The 2012 LinkedIn breach leaked 6.5 million SHA1 hashes with no salt. Researchers cracked 90% within 72 hours. If LinkedIn had used salts, cracking would have required attacking each hash individually instead of cracking the entire database at once.

The 2013 Adobe breach used 3DES encryption (not even hashing) with a single key and no unique salts. Because identical passwords produced identical ciphertext, researchers could identify the most common passwords just by counting duplicates, then crack them based on password hints that were also leaked.

## Slow Hash Functions

### Why Fast Hashes Are the Problem

SHA256 was designed to hash data quickly. That's great for verifying file integrity or TLS handshakes, but terrible for password storage. A GPU can compute 3 billion SHA256 hashes per second. That means an attacker can try 3 billion passwords per second.

### How bcrypt and argon2 Fix This

bcrypt, scrypt, and argon2 are intentionally slow hash functions. They add a configurable "work factor" that controls how long each hash takes:

```
SHA256:  ~3,000,000 hashes/sec (CPU)  ~3,000,000,000 hashes/sec (GPU)
bcrypt:  ~300 hashes/sec (CPU)        ~50,000 hashes/sec (GPU)
argon2:  ~10 hashes/sec (CPU)         GPU-resistant by design
```

bcrypt at cost factor 12 takes about 250ms per hash. A user logging in waits 250ms (unnoticeable). An attacker trying 14 million dictionary words waits 40 days. Same math, completely different outcome.

argon2 goes further by requiring large amounts of memory per hash, which limits GPU parallelism. GPUs have thousands of cores but limited memory per core. argon2 exploits this by forcing each hash to use megabytes of RAM, making GPU cracking impractical.

### Why We Don't Crack Them

This tool only cracks fast hashes (MD5, SHA1, SHA256, SHA512). That's intentional. Cracking bcrypt with a 10,000-word dictionary at 300 hashes/sec takes 33 seconds. The same dictionary against SHA256 takes 3 milliseconds. The speed difference is the lesson.

## Industry Standards

**OWASP Password Storage Cheat Sheet** recommends:
- argon2id as the primary choice
- bcrypt with cost factor 10+ as the fallback
- Never MD5 or SHA-family for passwords
- Minimum 16-byte random salt per password

**NIST SP 800-63B** (Digital Identity Guidelines):
- Memorized secrets should be hashed with a salt using a key derivation function
- At least 10,000 iterations if using PBKDF2
- Check passwords against known breach databases

**MITRE CWE-916**: Use of Password Hash With Insufficient Computational Effort. Assigned to systems using MD5, SHA1, or SHA256 for password storage without a slow key derivation function.

## Testing Your Understanding

1. An attacker steals a database with 1 million SHA256 hashes, all unsalted. How does the lack of salt help the attacker beyond just rainbow tables?

2. A website requires passwords to be "at least 8 characters with uppercase, lowercase, number, and special character." Why doesn't this prevent rule-based attacks?

3. Why does argon2 specifically resist GPU acceleration while bcrypt only partially resists it?

4. You find a hash `5f4dcc3b5aa765d61d8327deb882cf99` in a breach dump. Without running any cracking tool, what can you determine about it just from looking at it?

## Further Reading

**Essential:**
- [How Passwords Are Stored](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html) (OWASP)
- [hashcat documentation](https://hashcat.net/wiki/) for understanding real world cracking techniques

**Deep Dive:**
- [Bcrypt paper](https://www.usenix.org/legacy/events/usenix99/provos/provos.pdf) by Provos and Mazieres (1999)
- [Argon2 specification](https://github.com/P-H-C/phc-winner-argon2/blob/master/argon2-specs.pdf) (Password Hashing Competition winner)
- [Have I Been Pwned](https://haveibeenpwned.com/) for checking if passwords appear in breach databases
