# Hash Cracker CLI Tool

## What This Is

A multi-threaded command line tool that recovers plaintext passwords from cryptographic hashes. It supports MD5, SHA1, SHA256, and SHA512 using three attack strategies: dictionary attacks from wordlists, brute force generation of all possible combinations, and rule-based mutations that transform dictionary words into common password variations like `P@ssw0rd123`.

## Why This Matters

When attackers breach a database, they don't get plaintext passwords. They get hashes. The security of every user in that database depends on how resistant those hashes are to cracking. Building a cracker teaches you exactly why unsalted fast hashes like MD5 are catastrophic for password storage, and why modern systems use bcrypt or argon2 instead.

**Real world scenarios where this applies:**
- Penetration testers use tools like hashcat and john the ripper to audit password strength after gaining access to hash dumps
- The 2012 LinkedIn breach leaked 6.5 million unsalted SHA1 hashes. Researchers cracked 90% within 72 hours
- The 2013 Adobe breach exposed 153 million accounts using 3DES encryption (not even hashing) with no unique salts. The same encrypted blob appeared millions of times because identical passwords produced identical ciphertext

## What You'll Learn

**Security Concepts:**
- Cryptographic hash functions: one-way transformations that can't be reversed
- Dictionary attacks: leveraging known password lists from real breaches
- Brute force attacks: exhaustive search through all possible character combinations
- Rule-based mutations: why `Password123!` is not a strong password
- Salting: what it prevents (rainbow tables) and what it doesn't prevent (targeted cracking)

**Technical Skills:**
- Policy-based template design in C++23 with concept constraints
- `std::expected` for composable error handling without exceptions
- `std::generator` for lazy evaluation with coroutines
- Memory-mapped file I/O with mmap for zero-copy wordlist reading
- Multi-threaded work partitioning with `std::jthread` and atomics
- OpenSSL EVP API for hash computation

**Tools and Techniques:**
- CMake with presets for reproducible builds
- GoogleTest for unit and integration testing
- OpenSSL for cryptographic hash functions
- Boost.program_options for CLI argument parsing

## Prerequisites

**Required knowledge:**
- C++ basics: classes, templates, lambdas, move semantics
- Understanding of what a hash function does (input goes in, fixed-length output comes out, you can't reverse it)
- Command line familiarity

**Tools you'll need:**
- GCC 14 or higher (C++23 support required)
- CMake 3.25+
- Ninja build system
- OpenSSL development headers
- Boost.program_options

**Helpful but not required:**
- Experience with templates and concepts
- Familiarity with threading and atomics
- Understanding of memory-mapped I/O

## Quick Start

```bash
cd PROJECTS/beginner/hash-cracker

./install.sh

hashcracker --hash 5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8 \
  --wordlist wordlists/10k-most-common.txt
```

Expected output: The tool auto-detects the hash as SHA256, searches the 10,000-word dictionary, and finds the password `password` in under a second. If your terminal supports it, you'll see a progress bar with speed and ETA while it runs.

Try brute force:
```bash
hashcracker --hash 187ef4436122d1cc2f40dc2b92f0eba0 \
  --bruteforce --charset lower --max-length 4 --type md5
```

Expected output: Generates all lowercase combinations up to 4 characters, finds `ab` after searching ~350,000 candidates.

## Project Structure

```
hash-cracker/
├── main.cpp                     CLI parsing and dispatch
├── src/
│   ├── config/Config.hpp        Constants, character sets, colors
│   ├── core/
│   │   ├── Concepts.hpp         Hasher and AttackStrategy concepts
│   │   └── Engine.hpp           Template engine (hasher + attack + threading)
│   ├── hash/
│   │   ├── EVPHasher.hpp        Unified OpenSSL EVP hasher template
│   │   ├── HashDetector.hpp     Auto-detect hash type from hex length
│   │   ├── MD5Hasher.hpp        Type alias for EVPHasher<EVP_md5, ...>
│   │   ├── SHA1Hasher.hpp       Type alias for EVPHasher<EVP_sha1, ...>
│   │   ├── SHA256Hasher.hpp     Type alias for EVPHasher<EVP_sha256, ...>
│   │   └── SHA512Hasher.hpp     Type alias for EVPHasher<EVP_sha512, ...>
│   ├── attack/
│   │   ├── DictionaryAttack     mmap wordlist reader with partitioning
│   │   ├── BruteForceAttack     Keyspace generator with partitioning
│   │   └── RuleAttack           Dictionary + mutation rules
│   ├── rules/RuleSet            Mutation transforms via std::generator
│   ├── io/MappedFile            RAII wrapper for mmap
│   ├── threading/ThreadPool     std::jthread work partitioning
│   └── display/Progress         Terminal progress display
├── tests/                       GoogleTest suite (38 tests)
├── wordlists/                   Included 10k common passwords
├── install.sh                   One-command setup
├── Justfile                     Build/test/clean commands
└── CMakeLists.txt               Build configuration
```

## Next Steps

1. **Understand the concepts** - Read [01-CONCEPTS.md](./01-CONCEPTS.md) to learn how hash cracking works and why it matters
2. **Study the architecture** - Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) to see how concepts, templates, and threading fit together
3. **Walk through the code** - Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for a detailed code walkthrough
4. **Extend the project** - Read [04-CHALLENGES.md](./04-CHALLENGES.md) to add GPU acceleration, rainbow tables, or new algorithms

## Common Issues

**"File not found" when using a wordlist**
```
Error: File not found
```
Solution: Paths are relative to where you run the command. Run from the project root directory, or use an absolute path.

**"Invalid hash format" error**
```
Error: Invalid hash format
```
Solution: The auto-detector validates that all characters are hexadecimal (0-9, a-f) and the length matches a known algorithm (32=MD5, 40=SHA1, 64=SHA256, 128=SHA512). Check for trailing whitespace or non-hex characters.

**Brute force is slow on long passwords**
This is expected. The keyspace grows exponentially. 6 lowercase characters = 308 million combinations. Add digits and it's 2.2 billion. Add uppercase and special characters and you're looking at hours or days. This is the whole point: strong passwords resist brute force.
