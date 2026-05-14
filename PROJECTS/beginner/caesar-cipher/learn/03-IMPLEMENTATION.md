# Implementation Guide

This document walks through the actual code. We'll build key features step by step and explain the decisions along the way.

## File Structure Walkthrough
```
caesar-cipher/
├── src/caesar_cipher/
│   ├── __init__.py     # Package exports for CaesarCipher and FrequencyAnalyzer
│   ├── cipher.py       # Core encryption/decryption logic (62 lines)
│   ├── analyzer.py     # Chi-squared frequency analysis (60 lines)
│   ├── constants.py    # English letter frequencies, alphabet (43 lines)
│   ├── main.py         # Typer CLI with 3 commands (171 lines)
│   └── utils.py        # File I/O and validation (40 lines)
├── tests/
│   ├── test_cipher.py  # Cipher tests with edge cases
│   ├── test_analyzer.py # Frequency analysis tests
│   └── test_cli.py     # End-to-end CLI tests
└── pyproject.toml      # Dependencies and tool config
```

## Building the Core Cipher

### Step 1: Character Shifting

What we're building: The fundamental operation that takes one letter and shifts it by N positions.

In `cipher.py:30-40`:
```python
def _shift_char(self, char: str, shift: int) -> str:
    """
    Shift a single character by the specified amount while preserving case
    """
    if char in UPPERCASE_LETTERS:
        idx = UPPERCASE_LETTERS.index(char)
        return UPPERCASE_LETTERS[(idx + shift) % ALPHABET_SIZE]
    if char in LOWERCASE_LETTERS:
        idx = LOWERCASE_LETTERS.index(char)
        return LOWERCASE_LETTERS[(idx + shift) % ALPHABET_SIZE]
    return char
```

**Why this code works:**
- Line 35-36: Uppercase letters shift within uppercase. 'A' + 3 = 'D'. The modulo handles wrapping ('Z' + 1 = 'A').
- Line 37-39: Lowercase letters shift within lowercase independently. Preserves case.
- Line 40: Non-letters return unchanged. Spaces, punctuation, numbers pass through.

**Common mistakes here:**
```python
# Wrong approach - converts everything to uppercase
def shift_char(char, shift):
    if char.isalpha():
        idx = ord(char.upper()) - ord('A')
        return chr((idx + shift) % 26 + ord('A'))
    return char

# Why this fails: "Hello" becomes "KHOOR" instead of "Khoor"
```

You need separate handling for upper and lower case. The code uses two different alphabet strings (`UPPERCASE_LETTERS` and `LOWERCASE_LETTERS` from constants.py) to preserve case naturally.

### Step 2: Full Message Encryption

Now we need to apply the shift to every character in the message.

In `cipher.py:43-46`:
```python
def encrypt(self, plaintext: str) -> str:
    """
    Encrypt plaintext using the configured shift key
    """
    return "".join(self._shift_char(char, self.key) for char in plaintext)
```

**What's happening:**
1. Generator expression iterates each character: `for char in plaintext`
2. Calls `_shift_char()` with the instance's key
3. Joins all results into a string

**Why we do it this way:**
This is more memory efficient than building a list and joining. For huge texts, the generator yields characters one at a time instead of storing all shifted characters in memory.

**Alternative approaches:**
- Loop with `result += shifted_char`: Works but creates intermediate strings (O(n²) time in the worst case)
- List comprehension then join: `"".join([...])`: Uses more memory but same speed

### Step 3: Decryption (The Inverse Operation)

In `cipher.py:48-52`:
```python
def decrypt(self, ciphertext: str) -> str:
    """
    Decrypt ciphertext using the configured shift key
    """
    return "".join(self._shift_char(char, -self.key) for char in ciphertext)
```

**Key parts explained:**

Decryption is just encryption with a negative key. If we encrypted with +3, we decrypt with -3. The `_shift_char()` method handles negative shifts automatically via modulo arithmetic:
```
'K' is position 10
Shift by -3: (10 + (-3)) % 26 = 7 % 26 = 7
Position 7 is 'H'
```

Python's modulo operator handles negatives correctly: `(-1) % 26 = 25`, which wraps 'A' back to 'Z'.

## Building the Brute Force Cracker

### The Problem

You have ciphertext but don't know the key. With only 26 possibilities, try them all.

### The Solution

Generate all 26 decryptions and let frequency analysis pick the best one.

### Implementation

In `cipher.py:53-60`:
```python
@staticmethod
def crack(ciphertext: str) -> list[tuple[int, str]]:
    """
    Attempt all possible shifts to decrypt ciphertext without knowing the key
    """
    results = []
    for shift in range(ALPHABET_SIZE):
        cipher = CaesarCipher(key=shift)
        decrypted = cipher.decrypt(ciphertext)
        results.append((shift, decrypted))
    return results
```

**Why static method:**
This doesn't operate on a specific instance. It generates all possible instances. Making it static makes the intent clear: `CaesarCipher.crack(text)` is like asking "what are all Caesar decryptions of this text?"

**Optimization we didn't do:**
We could avoid creating 26 cipher objects and just call `_shift_char()` directly. But clarity beats micro-optimization here. Creating 26 objects is negligible.

## Building Frequency Analysis

### The Problem

When you crack a message, you get 26 candidates. Which one is real English?

### The Solution

Score each candidate by how closely its letter frequencies match known English frequencies. Lower chi-squared scores mean better matches.

### Implementation

In `analyzer.py:27-42`:
```python
def calculate_chi_squared(self, text: str) -> float:
    """
    Calculate chi-squared statistic comparing text to expected English frequencies
    """
    text_upper = text.upper()
    letter_counts = Counter(char for char in text_upper if char.isalpha())
    
    if not letter_counts:
        return float("inf")
    
    total_letters = sum(letter_counts.values())
    chi_squared = 0.0
    
    for letter, expected_freq in self.reference_frequencies.items():
        observed_count = letter_counts.get(letter, 0)
        expected_count = (expected_freq / 100) * total_letters
        
        if expected_count > 0:
            chi_squared += ((observed_count - expected_count)**2) / expected_count
    
    return chi_squared
```

**Breaking it down:**

**Lines 29-30:** Convert to uppercase and count only letters. `Counter` gives us `{'H': 1, 'E': 1, 'L': 2, 'O': 1}` for "HELLO".

**Lines 32-33:** Empty text has infinite badness. Can't score nothing.

**Line 35:** Total count needed to convert percentages to expected counts.

**Lines 38-41:** For each letter A-Z, compare observed vs expected:
- Expected: If the text has 100 letters and E should be 12.7%, we expect 12.7 letters of E
- Observed: How many E's are actually there
- Chi-squared adds up squared differences normalized by expected values

Lower scores mean closer to English. Gibberish has wild frequency distributions and scores high.

### Ranking Candidates

In `analyzer.py:53-60`:
```python
def rank_candidates(self, candidates: list[tuple[int, str]]) -> list[tuple[int, str, float]]:
    """
    Rank decryption candidates by their English frequency score
    """
    scored = [
        (shift, text, self.score_text(text)) 
        for shift, text in candidates
    ]
    return sorted(scored, key=lambda x: x[2])
```

Takes list of `(shift, decrypted_text)` tuples, adds scores, sorts by score (ascending, so best is first).

## CLI Implementation

### Command Structure

The tool has three commands: encrypt, decrypt, crack. All use similar patterns.

**Encrypt command** (`main.py:24-60`):
```python
@app.command()
def encrypt(
    text: Annotated[str | None, typer.Argument(...)] = None,
    key: Annotated[int, typer.Option("--key", "-k", ...)] = 3,
    input_file: Annotated[Path | None, typer.Option(...)] = None,
    output_file: Annotated[Path | None, typer.Option(...)] = None,
    quiet: Annotated[bool, typer.Option(...)] = False,
) -> None:
```

**The Annotated syntax:**
Typer uses type hints to generate the CLI. `Annotated[str | None, typer.Argument(...)]` means "this is an optional string argument". The help text is in the `Argument()` call.

**Validation flow:**
```python
try:
    validate_key(key)  # utils.py:36
    plaintext = read_input(text, input_file)  # utils.py:11
    cipher = CaesarCipher(key=key)
    encrypted = cipher.encrypt(plaintext)
    # ... output ...
except (ValueError, OSError) as e:
    console.print(f"[red]Error:[/red] {e}")
    raise typer.Exit(code=1) from None
```

**Error handling:**
Catch both `ValueError` (from validation) and `OSError` (from file operations). Print error in red using Rich, then exit with code 1. The `from None` suppresses the exception chain in the output.

### Input Handling

Three ways to provide input: command line argument, file, or stdin.

In `utils.py:11-24`:
```python
def read_input(text: str | None, input_file: Path | None) -> str:
    """
    Read input from text argument, file, or stdin
    """
    if text:
        return text
    
    if input_file:
        return input_file.read_text(encoding="utf-8")
    
    if not sys.stdin.isatty():
        return sys.stdin.read()
    
    raise ValueError("No input provided. Use TEXT argument, --input-file, or pipe to stdin")
```

**Priority order:**
1. Explicit text argument
2. Input file
3. Stdin (but only if it's piped, not interactive terminal)

**The `sys.stdin.isatty()` check:**
Returns `False` when input is piped: `echo "test" | caesar-cipher encrypt`. Returns `True` when running interactively. We only read stdin if it's piped to avoid hanging waiting for user input that won't come.

### Rich Table Output

The crack command displays results in a formatted table.

In `main.py:135-148`:
```python
table = Table(title="Caesar Cipher Brute Force Results")
table.add_column("Rank", style="cyan", justify="right")
table.add_column("Shift", style="magenta", justify="right")
table.add_column("Score", style="yellow", justify="right")
table.add_column("Decrypted Text", style="green")

display_count = len(ranked) if show_all else min(top, len(ranked))

for rank, (shift, text_result, score) in enumerate(ranked[:display_count], 1):
    table.add_row(
        str(rank),
        str(shift),
        f"{score:.2f}",
        text_result[:80]  # Truncate long text
    )

console.print(table)
```

**Why Rich:**
Colored output makes it obvious which columns are which. The table auto-formats and aligns columns. Much nicer than printing tab-separated values.

**Truncation:**
`text_result[:80]` limits displayed text to 80 characters. Otherwise really long decryptions make the table unreadable.

## Testing Strategy

### Unit Tests for Cipher

Example test for encryption (`test_cipher.py:14-16`):
```python
def test_encrypt_basic(self) -> None:
    cipher = CaesarCipher(key=3)
    assert cipher.encrypt("HELLO") == "KHOOR"
```

**What this tests:**
Basic shift functionality. If this fails, everything is broken.

**Edge cases tested:**
- Wraparound: `test_alphabet_wraparound_uppercase()` checks 'XYZ' → 'ABC'
- Case preservation: `test_encrypt_mixed_case()` checks "Hello World" → "Khoor Zruog"
- Non-letters: `test_encrypt_preserves_punctuation()` checks "Hello!" → "Khoor!"
- Empty string: `test_empty_string()` checks "" → ""

**Roundtrip test** (`test_cipher.py:42-46`):
```python
def test_encrypt_decrypt_roundtrip(self) -> None:
    cipher = CaesarCipher(key=13)
    original = "The Quick Brown Fox Jumps Over The Lazy Dog!"
    encrypted = cipher.encrypt(original)
    decrypted = cipher.decrypt(encrypted)
    assert decrypted == original
```

This catches asymmetry bugs. If encrypt and decrypt aren't true inverses, this fails.

### Integration Tests for Analyzer

Testing that frequency analysis actually picks the right answer (`test_analyzer.py:44-54`):
```python
def test_rank_candidates_with_actual_cipher(self) -> None:
    cipher = CaesarCipher(key=3)
    plaintext = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG"
    ciphertext = cipher.encrypt(plaintext)
    
    candidates = CaesarCipher.crack(ciphertext)
    analyzer = FrequencyAnalyzer()
    ranked = analyzer.rank_candidates(candidates)
    
    best_shift, best_text, _best_score = ranked[0]
    assert best_shift == 3
    assert best_text == plaintext
```

This is an integration test because it uses both cipher and analyzer together. It verifies the whole crack workflow works end to end.

### CLI Tests

Testing the actual commands (`test_cli.py:14-18`):
```python
def test_encrypt_basic(self) -> None:
    result = runner.invoke(app, ["encrypt", "HELLO", "--key", "3"])
    assert result.exit_code == 0
    assert "KHOOR" in result.stdout
```

Uses Typer's test runner to simulate command line invocation. Checks exit code and output.

**File I/O test** (`test_cli.py:63-73`):
```python
def test_encrypt_from_file(self, tmp_path: Path) -> None:
    input_file = tmp_path / "input.txt"
    input_file.write_text("HELLO WORLD")
    
    result = runner.invoke(
        app,
        ["encrypt", "--input-file", str(input_file), "--key", "3"]
    )
    assert result.exit_code == 0
    assert "KHOOR ZRUOG" in result.stdout
```

Creates a temp file, reads from it, verifies output. This tests the file handling path without leaving artifacts.

## Common Implementation Pitfalls

### Pitfall 1: Forgetting to Handle Negative Keys

**Symptom:**
Crash or wrong output when using `--key -3`.

**Cause:**
```python
# Problematic code - doesn't normalize negative keys
def __init__(self, key: int):
    self.key = key  # If key=-3, modulo in _shift_char breaks
```

**Fix:**
```python
# Correct approach (cipher.py:23)
self.key = key % ALPHABET_SIZE
```

Normalizing during construction means all other code can assume key is 0-25.

**Why this matters:**
Caesar cipher with key=-3 is the same as key=23. Both shift left by 3. Normalizing makes them equivalent.

### Pitfall 2: Not Handling Empty Input

**Symptom:**
Division by zero in chi-squared calculation.

**Cause:**
```python
# Bad - crashes if text is empty
def calculate_chi_squared(text):
    total = sum(counts.values())
    # ... expected_count / total will divide by zero
```

**Fix:**
```python
# Good - early return (analyzer.py:32-33)
if not letter_counts:
    return float("inf")
```

Empty text has infinitely bad frequency match. Can't be English if there are no letters.

### Pitfall 3: Mixing Up Encryption and Decryption

**Symptom:**
`decrypt("KHOOR")` with key=3 gives gibberish instead of "HELLO".

**Cause:**
```python
# Wrong - decrypt shifts forward instead of backward
def decrypt(self, ciphertext):
    return self.encrypt(ciphertext)  # This is just double encryption!
```

**Fix:**
```python
# Right - decrypt shifts backward (cipher.py:51)
return "".join(self._shift_char(char, -self.key) for char in ciphertext)
```

Decryption must reverse the shift. Negative key does this.

## Debugging Tips

### Issue Type 1: Frequency Analysis Gives Wrong Answer

**Problem:** The best ranked candidate isn't the correct decryption.

**How to debug:**
1. Check `constants.py:17-43` - Are the English frequencies correct?
2. Print scores for all 26 candidates - Is the correct one close to the top?
3. Try with longer ciphertext - Short text doesn't have enough letters for reliable frequency analysis

**Common causes:**
- Text is too short (under 50 letters)
- Text isn't English (frequency analysis assumes English)
- Text has unusual word distribution (technical jargon, names)

### Issue Type 2: CLI Hangs When Running Command

**Problem:** `caesar-cipher encrypt --key 3` hangs forever.

**How to debug:**
1. Check if you forgot to provide input text
2. Look at `utils.py:20-21` - If stdin isn't a TTY, it waits for piped input
3. Either provide text: `caesar-cipher encrypt "HELLO" --key 3` or pipe it: `echo "HELLO" | caesar-cipher encrypt --key 3`

**Common cause:**
Running the command without text and without piping stdin. The code waits for input that never comes.

## Code Organization Principles

### Why cipher.py is Independent
```
cipher.py
├── Only imports from constants
├── No CLI dependencies
└── No analyzer dependencies
```

We separate the cipher from its applications because:
- You can unit test encryption without mocking CLI
- The cipher could be used in a web API without changing anything
- Testing focuses on algorithm correctness, not I/O

This makes the codebase easier to reason about. If tests in `test_cipher.py` pass, the algorithm is correct regardless of how it's invoked.

### Naming Conventions

- `_shift_char` (leading underscore) = Internal helper method, not part of public API
- `UPPERCASE_LETTERS` (all caps) = Constant that shouldn't change
- `crack` (verb) = Methods are actions

Following these patterns makes it easier to distinguish between public API, internal implementation, and configuration.

## Extending the Code

### Adding a New Alphabet

Want to support numbers in encryption? Here's the process:

1. **Modify constants** in `constants.py:10-11`
```python
   DIGITS = string.digits
   ALL_CHARS = UPPERCASE_LETTERS + LOWERCASE_LETTERS + DIGITS
```

2. **Update _shift_char** in `cipher.py:30-40`
```python
   def _shift_char(self, char: str, shift: int) -> str:
       if char in UPPERCASE_LETTERS:
           idx = UPPERCASE_LETTERS.index(char)
           return UPPERCASE_LETTERS[(idx + shift) % 26]
       if char in LOWERCASE_LETTERS:
           idx = LOWERCASE_LETTERS.index(char)
           return LOWERCASE_LETTERS[(idx + shift) % 26]
       if char in DIGITS:
           idx = DIGITS.index(char)
           return DIGITS[(idx + shift) % 10]  # 10 digits
       return char
```

3. **Add tests** in `test_cipher.py`
```python
   def test_encrypt_digits(self) -> None:
       cipher = CaesarCipher(key=3)
       assert cipher.encrypt("Test123") == "Whvw456"
```

The architecture makes this easy because cipher logic is isolated from everything else.

## Dependencies

### Why Each Dependency

- **typer** (0.20.0): CLI framework with automatic help and type hints. Better than argparse for modern Python.
- **rich** (14.2.0): Colored terminal output and table formatting. Makes the crack command output readable.
- **pytest** (9.0.2): Test framework. Standard for Python testing.
- **mypy** (1.19.0): Static type checker. Catches type errors before runtime.
- **ruff** (0.14.8): Fast linter combining many tools. Replaces flake8, isort, black.

### Dependency Security

Check for vulnerabilities:
```bash
pip install pip-audit
pip-audit
```

If you see a vulnerability in typer or rich, check if there's a newer version that fixes it. Update the version constraints in `pyproject.toml:7-9`.

## Build and Deploy

### Building
```bash
# Install in development mode
pip install -e .

# Or build a wheel
pip install build
python -m build
```

This produces a wheel in `dist/` that can be installed anywhere.

### Local Development
```bash
# Install with dev dependencies
pip install -e ".[dev]"

# Run tests
pytest

# Run linter
ruff check src/ tests/

# Run type checker
mypy src/
```

The `[dev]` extra includes testing and linting tools from `pyproject.toml:10-17`.

### Production Deployment

For a CLI tool, "production" means publishing to PyPI:
```bash
# Build
python -m build

# Upload to PyPI
python -m twine upload dist/*
```

Then users install with `pip install caesar-salad-cipher` and get the `caesar-cipher` command in their PATH.

## Next Steps

You've seen how the code works. Now:

1. **Try the challenges** - [04-CHALLENGES.md](./04-CHALLENGES.md) has extension ideas like Vigenère cipher
2. **Modify the code** - Change the frequency scoring to use bigrams (two-letter pairs) instead of single letters
3. **Read related projects** - Look at real-world frequency analysis tools for inspiration
