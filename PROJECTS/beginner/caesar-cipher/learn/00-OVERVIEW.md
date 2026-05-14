# Caesar Cipher CLI Tool

## What This Is

A command line tool that implements the Caesar cipher, one of the oldest known encryption techniques. It shifts each letter in your text by a fixed number of positions in the alphabet. The tool can encrypt messages, decrypt them if you know the key, or crack encrypted text by trying all possible shifts and ranking them using frequency analysis.

## Why This Matters

The Caesar cipher is weak by modern standards, but understanding how to break it teaches fundamental cryptanalysis skills that apply to stronger systems. Every security professional should know why simple substitution ciphers fail.

**Real world scenarios where this applies:**
- ROT13 is still used for spoiler text on forums and in email (it's Caesar with key=13)
- Understanding frequency analysis helps you break other substitution ciphers found in CTF challenges
- The concept of brute forcing a small key space applies to weak passwords, short PINs, and poorly designed crypto

## What You'll Learn

This project teaches you how classical cryptography breaks down under statistical analysis. By building it yourself, you'll understand:

**Security Concepts:**
- Substitution ciphers: how they work and why character frequency gives them away
- Brute force attacks: when the key space is small enough (26 possibilities here), trying everything is trivial
- Frequency analysis: real English text has predictable letter patterns that survive encryption

**Technical Skills:**
- Chi-squared statistical testing to score how "English-like" text appears
- Building CLI tools with proper argument parsing (using Typer)
- Implementing both encryption and cryptanalysis in the same codebase

**Tools and Techniques:**
- Typer for command line interfaces with automatic help text
- Rich library for colored terminal output and formatted tables
- Python's Counter for frequency counting and statistical analysis

## Prerequisites

Before starting, you should understand:

**Required knowledge:**
- Python basics: functions, classes, list comprehensions
- String manipulation: iterating characters, checking if they're letters
- Modular arithmetic: why `(25 + 3) % 26 = 2` wraps around the alphabet

**Tools you'll need:**
- Python 3.12 or higher
- pip for installing dependencies
- A terminal where you can run commands

**Helpful but not required:**
- Basic statistics (what chi-squared means)
- Some exposure to encryption concepts

## Quick Start

Get the project running locally:
```bash
# Clone and navigate
cd PROJECTS/beginner/caesar-cipher

# Install with dependencies
pip install -e .

# Encrypt some text
caesar-cipher encrypt "HELLO WORLD" --key 3

# Decrypt it back
caesar-cipher decrypt "KHOOR ZRUOG" --key 3

# Crack it without knowing the key
caesar-cipher crack "KHOOR ZRUOG"
```

Expected output: You should see `KHOOR ZRUOG` when encrypting, `HELLO WORLD` when decrypting, and a ranked table of all 26 possible decryptions when cracking (with the correct one at the top).

## Project Structure
```
caesar-cipher/
├── src/caesar_cipher/
│   ├── cipher.py         # Core encryption/decryption logic
│   ├── analyzer.py       # Frequency analysis for cracking
│   ├── constants.py      # English letter frequencies, alphabet
│   ├── main.py          # CLI commands (encrypt/decrypt/crack)
│   └── utils.py         # File I/O and input validation
├── tests/               # Pytest test suite
└── pyproject.toml      # Project dependencies and config
```

## Next Steps

1. **Understand the concepts** - Read [01-CONCEPTS.md](./01-CONCEPTS.md) to learn why Caesar ciphers are broken
2. **Study the architecture** - Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) to see how the pieces fit together
3. **Walk through the code** - Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for line by line explanation
4. **Extend the project** - Read [04-CHALLENGES.md](./04-CHALLENGES.md) to build variants like Vigenère cipher

## Common Issues

**"Key must be between -25 and 26" error**
```
ValueError: Key must be between -25 and 26
```
Solution: Caesar cipher only makes sense with shifts from -25 to 26. Use a key in that range. The code validates this in `cipher.py:20-22`.

**No output when piping from stdin**
Solution: Make sure you're actually sending text. Try `echo "TEST" | caesar-cipher encrypt --key 5` instead of just `caesar-cipher encrypt --key 5`.
