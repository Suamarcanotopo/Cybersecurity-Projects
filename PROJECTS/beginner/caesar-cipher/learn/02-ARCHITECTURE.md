# System Architecture

This document breaks down how the system is designed and why certain architectural decisions were made.

## High Level Architecture
```
┌─────────────────┐
│   CLI Layer     │  (main.py)
│  - encrypt cmd  │  Typer commands, Rich output
│  - decrypt cmd  │  
│  - crack cmd    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Cipher Layer   │  (cipher.py)
│  - CaesarCipher │  Core algorithm
│  - shift logic  │  Encryption/decryption
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Analysis Layer  │  (analyzer.py)
│ - chi-squared   │  Statistical scoring
│ - rank results  │  Frequency comparison
└─────────────────┘
         │
         ▼
┌─────────────────┐
│  Utils Layer    │  (utils.py, constants.py)
│  - file I/O     │  Support functions
│  - validation   │  Reference data
└─────────────────┘
```

### Component Breakdown

**CLI Layer (main.py)**
- Purpose: User-facing commands that parse arguments and call core functions
- Responsibilities: Input validation, file handling, formatted output with Rich tables
- Interfaces: Exposes three commands via Typer (encrypt, decrypt, crack)

**Cipher Layer (cipher.py)**
- Purpose: Implements the actual Caesar cipher algorithm
- Responsibilities: Character shifting, key validation, brute force generation
- Interfaces: `CaesarCipher` class with `encrypt()`, `decrypt()`, and static `crack()` method

**Analysis Layer (analyzer.py)**
- Purpose: Statistical analysis to identify correct decryptions
- Responsibilities: Chi-squared calculation, candidate ranking by English frequency
- Interfaces: `FrequencyAnalyzer` class that scores and ranks text

**Utils Layer (utils.py, constants.py)**
- Purpose: Shared functionality and reference data
- Responsibilities: Reading from files/stdin, writing output, storing English letter frequencies
- Interfaces: Standalone functions and constants used across other layers

## Data Flow

### Encryption Flow

Step by step walkthrough of encrypting text:
```
1. User Input → CLI Parser (main.py:34-56)
   Validates key is 0-25, reads text from arg/file/stdin

2. CLI → CaesarCipher (cipher.py:13-28)
   Creates cipher instance with validated key

3. CaesarCipher → Encryption Loop (cipher.py:43-46)
   Shifts each character, preserves non-letters
   
4. Encrypted Text → Output (main.py:56-60)
   Writes to file or prints with Rich formatting
```

Example with code references:
```
1. User runs: caesar-cipher encrypt "HELLO" --key 3
   main.py:34 → validates key with utils.validate_key()
   main.py:47 → reads input via read_input()

2. main.py:48 → Creates CaesarCipher(key=3)
   cipher.py:16 → Stores key % 26 to handle wrapping

3. main.py:49 → Calls cipher.encrypt("HELLO")
   cipher.py:43-46 → Iterates each char with _shift_char()
   cipher.py:31-38 → Shifts H→K, E→H, L→O, L→O, O→R

4. main.py:52 → Outputs "KHOOR" via console.print()
```

### Cracking Flow

More complex: tries all keys and ranks by frequency.
```
1. User Input → CLI (main.py:108-128)
   Reads ciphertext, gets options (--top N, --all)

2. CLI → Brute Force (cipher.py:53-60)
   Generates all 26 possible decryptions

3. Candidates → Frequency Analysis (analyzer.py:53-60)
   Scores each with chi-squared test

4. Ranked Results → Table Output (main.py:135-148)
   Displays top matches in Rich table
```

## Design Patterns

### Strategy Pattern (Implicit)

**What it is:**
Separating the algorithm (cipher operations) from its application (CLI commands).

**Where we use it:**
The `CaesarCipher` class in `cipher.py` is independent of how it's invoked. You could use it from a web API, GUI, or CLI without changing the cipher code.

**Why we chose it:**
Separation of concerns makes testing easier. The cipher logic has zero dependencies on Typer or Rich. You can test `cipher.py` without dealing with command line argument parsing.

**Trade-offs:**
- Pros: Clean interfaces, easy to test, reusable components
- Cons: More files than a single script, slightly more complex for a simple project

### Factory Pattern (Static Methods)

**What it is:**
Using `@staticmethod` to create variations without instantiation.

**Where we use it:**
```python
# cipher.py:52-60
@staticmethod
def crack(ciphertext: str) -> list[tuple[int, str]]:
    results = []
    for shift in range(ALPHABET_SIZE):
        cipher = CaesarCipher(key=shift)
        decrypted = cipher.decrypt(ciphertext)
        results.append((shift, decrypted))
    return results
```

**Why we chose it:**
The `crack()` method doesn't belong to any particular key value. It generates all possible instances. Making it static makes the API clearer: `CaesarCipher.crack()` reads like "try all Caesar keys" without needing an instance.

## Layer Separation
```
┌────────────────────────────────────┐
│    CLI Layer (main.py)             │
│    - User interaction              │
│    - Does not do crypto            │
└────────────────────────────────────┘
           ↓
┌────────────────────────────────────┐
│    Business Logic (cipher.py)      │
│    - Core algorithm                │
│    - Does not know about CLI       │
└────────────────────────────────────┘
           ↓
┌────────────────────────────────────┐
│    Support (utils.py)              │
│    - Generic helpers               │
│    - No domain logic               │
└────────────────────────────────────┘
```

### Why Layers?

Prevents dependencies from becoming circular. CLI can import cipher, but cipher doesn't import CLI. This means:
- You can test the cipher without mocking Typer
- You could use the cipher in a different interface (web, GUI) without modification
- Changes to output formatting don't affect cryptographic correctness

### What Lives Where

**CLI Layer (main.py):**
- Files: `main.py`
- Imports: Can import from cipher, analyzer, utils
- Forbidden: No crypto logic, no direct alphabet manipulation

**Business Layer (cipher.py, analyzer.py):**
- Files: `cipher.py`, `analyzer.py`
- Imports: Can import constants, utils. Cannot import main.
- Forbidden: No command line parsing, no Rich formatting

**Support Layer (utils.py, constants.py):**
- Files: `utils.py`, `constants.py`
- Imports: Standard library only
- Forbidden: No domain logic, stays generic

## Data Models

### CaesarCipher
```python
# cipher.py:13-28
class CaesarCipher:
    def __init__(self, key: int, alphabet: str | None = None) -> None:
        if not -25 <= key <= 26:
            raise ValueError("Key must be between -25 and 26")
        
        self.key = key % ALPHABET_SIZE
        self.alphabet = alphabet or (UPPERCASE_LETTERS + LOWERCASE_LETTERS)
```

**Fields explained:**
- `key`: The shift amount, normalized to 0-25 via modulo. Storing it this way means encryption never has to handle wrapping again.
- `alphabet`: Normally just A-Z + a-z, but configurable for custom alphabets. Not used in CLI but extensible.

**Relationships:**
- Uses constants from `constants.py` (ALPHABET_SIZE, letter sets)
- Used by all three CLI commands
- Has no dependencies on analyzer (one-way relationship)

### FrequencyAnalyzer
```python
# analyzer.py:11-16
class FrequencyAnalyzer:
    def __init__(self) -> None:
        self.reference_frequencies = ENGLISH_LETTER_FREQUENCIES
```

**Fields explained:**
- `reference_frequencies`: Dictionary mapping 'A'-'Z' to their expected percentages in English text. Loaded from `constants.py:17-43`.

**Relationships:**
- Used only by the `crack` command
- Operates on output from `CaesarCipher.crack()`
- No dependencies on the cipher itself

## Security Architecture

### Threat Model

What we're protecting against:
1. **None** - This is an educational tool. The cipher is intentionally weak.
2. **Input Validation** - Prevents crashes from bad keys or missing input
3. **File Injection** - Uses Path objects and explicit encoding to avoid issues

What we're NOT protecting against (out of scope):
- Cryptanalysis - The cipher is meant to be broken
- Side-channel attacks - This is Python, timing isn't constant
- Key recovery - The key space is trivially small

### Defense Layers

This project doesn't have security defenses because it's teaching cryptanalysis, not building secure crypto. But it does have input validation:
```
Layer 1: Key validation (utils.py:36-40, cipher.py:19-22)
    ↓
Layer 2: Input source validation (utils.py:11-24)
    ↓
Layer 3: File encoding (utils.py:17, 32)
```

The validation ensures the program doesn't crash, but there's no security boundary. Don't use Caesar cipher for actual secrets.

## Storage Strategy

### No Persistent Storage

This tool is stateless. Everything happens in memory. Input comes from arguments/files/stdin, output goes to stdout/files, and nothing is saved.

**Why this choice:**
Simplicity. There's no need to track history or save state. Each command is independent.

## Configuration

### Environment Variables

None. The project uses command line arguments exclusively.

### Configuration Strategy

**Development:**
```bash
pip install -e .  # Editable install
```

All configuration is in `pyproject.toml`. Dependencies, linter settings, test config all live there.

**Production:**
```bash
pip install .  # Regular install
```

Same configuration. This isn't deployed to production because it's a teaching tool, but if it were, the config doesn't change.

## Performance Considerations

### Bottlenecks

Where this system gets slow under load:
1. **Frequency analysis on huge files** - The chi-squared calculation is O(n) where n is text length. For multi-MB files, this adds up when run 26 times.
2. **Rich table rendering** - Printing 26 rows of output is slower than plain text.

Neither matters in practice. The cipher itself is so fast that I/O dominates.

### Optimizations

What we did to make it faster:
- **List comprehension in encrypt()**: Using `"".join(self._shift_char(char, self.key) for char in plaintext)` in `cipher.py:46` instead of building a list and joining is more memory efficient.
- **Early return in chi-squared**: If there are no letters at all, return infinity immediately (analyzer.py:33) instead of trying to calculate on empty data.

### Scalability

**Vertical scaling:**
Doesn't apply. Single-threaded Python processing text. More CPU doesn't help.

**Horizontal scaling:**
You could parallelize the crack command to try all 26 shifts in parallel, but it's already instant. Not worth the complexity.

## Design Decisions

### Decision 1: Separate Cipher and Analyzer Classes

**What we chose:**
Keep encryption logic in `CaesarCipher`, statistical analysis in `FrequencyAnalyzer`.

**Alternatives considered:**
- Put everything in one class - Rejected because mixing crypto and cryptanalysis in the same object is conceptually wrong
- Make analyzer functions instead of a class - Rejected because the reference frequencies are shared state

**Trade-offs:**
We get cleaner separation and better testability. The cost is two imports instead of one when you want to crack messages.

### Decision 2: CLI with Typer Instead of argparse

**What we chose:**
Use Typer for automatic help generation and type hints.

**Alternatives considered:**
- argparse (stdlib) - More verbose, no type hints
- click - Similar to Typer but without the type hint magic

**Trade-offs:**
Typer gives clean code at the cost of an extra dependency. For a learning project, the better code readability is worth it.

### Decision 3: Preserve Case and Non-Letters

**What we chose:**
Encrypt only A-Z and a-z, leave spaces/punctuation/numbers unchanged.

**Alternatives considered:**
- Convert everything to uppercase - Loses information, makes output uglier
- Encrypt spaces too - Historical Caesar didn't do this, less authentic

**Trade-offs:**
Preserving case makes the output more readable but slightly complicates the shifting logic (need to check uppercase vs lowercase separately).

## Deployment Architecture

This is a local CLI tool, not a deployed service. Installation is via pip:
```bash
pip install caesar-salad-cipher
```

The `pyproject.toml:31-32` entry point makes the command available:
```toml
[project.scripts]
caesar-cipher = "caesar_cipher.main:app"
```

After installation, `caesar-cipher` is in your PATH and calls `main.py:app()`.

## Error Handling Strategy

### Error Types

1. **Invalid Key** - Key outside -25 to 26 range
   - Raised by `cipher.py:20-22` and `utils.py:36-40`
   - Caught in `main.py:59, 97, 152` and printed as error

2. **Missing Input** - No text provided
   - Raised by `utils.py:23` if all sources (arg, file, stdin) are empty
   - Caught in main commands

3. **File Not Found** - Input file doesn't exist
   - Raised by `Path.read_text()` in `utils.py:17`
   - Caught generically as OSError

### Recovery Mechanisms

There's no automatic recovery. The tool exits with code 1 on error:
```python
# main.py:59-60
except (ValueError, OSError) as e:
    console.print(f"[red]Error:[/red] {e}")
    raise typer.Exit(code=1) from None
```

**Why exit instead of retry:**
It's a CLI tool. If the user gave a bad key, they need to fix it and run again. No point staying alive.

## Extensibility

### Where to Add Features

Want to add support for numbers? Here's where it goes:

1. Modify `constants.py` to include '0'-'9' in the alphabet
2. Update `cipher.py:31-40` _shift_char() to handle digits
3. Adjust tests in `test_cipher.py` to verify digit shifting

Want to add Vigenère cipher?

1. Create `vigenere.py` with a similar class structure
2. Add `vigenere` command in `main.py`
3. Reuse `utils.py` for I/O, but frequency analysis won't work (Vigenère is polyalphabetic)

## Limitations

Current architectural limitations:
1. **Only works on Latin alphabet** - No support for Cyrillic, Arabic, or ideographic scripts. Fixing this would require multi-alphabet constants and different frequency tables.
2. **No key derivation** - The key is literally just a number. Can't use passwords. Would need a KDF (but that's overkill for Caesar).
3. **Single-threaded** - Can't take advantage of multiple cores. Not worth fixing when crack() runs in under a millisecond anyway.

These are not bugs, they're conscious trade-offs. The project is for learning classical crypto, not building production tools.

## Comparison to Similar Systems

### ROT13 Online Tools

How we're different:
- ROT13 tools only do shift=13. We support any key 0-25.
- We have frequency analysis built in for cracking.

Why we made different choices:
ROT13 is a special case. We're teaching the general algorithm and how to break it.

### CyberChef

CyberChef is a Swiss Army knife with dozens of encodings including Caesar. Our tool is purpose-built for learning cryptanalysis, so we include the statistical scoring and ranking that CyberChef doesn't emphasize.

## Key Files Reference

Quick map of where to find things:

- `src/caesar_cipher/cipher.py` - Core algorithm: _shift_char(), encrypt(), decrypt(), crack()
- `src/caesar_cipher/analyzer.py` - Chi-squared calculation and candidate ranking
- `src/caesar_cipher/main.py` - CLI commands and Rich table formatting
- `src/caesar_cipher/constants.py` - English letter frequencies (the key to breaking Caesar)
- `tests/test_cipher.py` - Encryption/decryption roundtrip tests
- `tests/test_analyzer.py` - Frequency analysis correctness tests

## Next Steps

Now that you understand the architecture:
1. Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for code walkthrough
2. Try modifying the shift algorithm to rotate in reverse (negative keys already work, but make the default behavior different)
