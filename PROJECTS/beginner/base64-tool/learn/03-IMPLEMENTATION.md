# Implementation

## constants.py — The Foundation

Everything that other modules depend on lives here. No business logic, just definitions.

### EncodingFormat Enum (line 10)

```python
class EncodingFormat(StrEnum):
    BASE64 = "base64"
    BASE64URL = "base64url"
    BASE32 = "base32"
    HEX = "hex"
    URL = "url"
```

`StrEnum` (Python 3.11+) means each member is also a string. You can compare `EncodingFormat.BASE64 == "base64"` and it's `True`. Typer uses this directly for the `--format` option: it auto-generates the choices from the enum values. No separate validation code needed.

### Character Sets (lines 34–46)

```python
BASE64_CHARSET: Final[frozenset[str]] = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
```

Each encoding's valid character set is a `frozenset` for O(1) membership testing. The detector checks `all(c in BASE64_CHARSET for c in stripped)`. With a frozenset, each character lookup is a hash table check instead of a linear scan. For short strings the difference is negligible, but it's the right data structure regardless.

`Final` from `typing` tells mypy these are constants that should never be reassigned.

### Thresholds (lines 24–33)

`PEEL_MAX_DEPTH = 20` caps recursion. In practice, even heavily obfuscated malware payloads rarely exceed 5–6 layers, but the cap prevents pathological inputs from running forever.

`CONFIDENCE_THRESHOLD = 0.6` is the minimum score for a detection to be considered valid. This value was tuned to avoid false positives while catching legitimate encodings. Too low and random strings trigger false detections. Too high and short or ambiguous encodings get missed.

`MIN_INPUT_LENGTH = 4` rejects trivially short inputs from detection. A 3-character string could match almost any format by coincidence.

## encoders.py — Pure Transformations

### Encode/Decode Functions (lines 22–70)

Each format has a dedicated encode and decode function. They're small, focused, and independently testable.

Notable implementation details:

**decode_base64 (line 26)**: Uses `validate=True` in `b64.b64decode()`. Without this flag, Python's base64 decoder silently ignores non-alphabet characters. With it, any invalid character raises `binascii.Error`. This is RFC 4648 strict compliance. The `01-CONCEPTS.md` doc explains why lax decoders create security issues (padding oracle attacks).

**decode_base64 and decode_base64url (lines 27, 36)**: Both call `"".join(data.split())` before decoding. This strips all whitespace (newlines, spaces, tabs). Base64 data often comes wrapped at 76 characters (MIME standard), and the decoder needs to handle that.

**decode_base32 (line 45)**: Calls `.upper()` after stripping whitespace. Base32's alphabet is uppercase only, but users might paste lowercase. Case-normalizing before decoding is more forgiving without being unsafe.

**decode_hex (lines 53–57)**: Strips common hex separators (space, colon, dash, dot). This means `AA:BB:CC`, `AA BB CC`, `AA-BB-CC`, and `AABBCC` all decode correctly. Real hex data comes in many formats: MAC addresses use colons, hex dumps use spaces, some tools use dashes.

**encode_url / decode_url (lines 60–70)**: Support a `form` keyword-only argument. Standard URL encoding uses `%20` for spaces. Form encoding (`application/x-www-form-urlencoded`) uses `+`. The distinction matters for web security testing, so both are supported. The `*` in `def encode_url(data: bytes, *, form: bool = False)` forces `form` to be keyword-only, preventing accidental positional usage.

### The Registry (lines 73–85)

```python
ENCODER_REGISTRY: dict[EncodingFormat, tuple[EncoderFn, DecoderFn]] = {
    EncodingFormat.BASE64: (encode_base64, decode_base64),
    ...
}
```

Functions are first-class objects in Python. This dict maps each format to its (encoder, decoder) pair. Dispatch is a dictionary lookup:

```python
def encode(data: bytes, fmt: EncodingFormat) -> str:
    encoder_fn, _ = ENCODER_REGISTRY[fmt]
    return encoder_fn(data)
```

The URL entry uses lambdas (`lambda data: encode_url(data)`) because the URL functions have an extra `form` parameter that doesn't match the `EncoderFn` / `DecoderFn` type signatures. The lambdas create wrapper functions with the default `form=False`.

### try_decode (lines 98–107)

```python
def try_decode(data: str, fmt: EncodingFormat) -> bytes | None:
    try:
        return decode(data, fmt)
    except (ValueError, binascii.Error, UnicodeDecodeError, UnicodeEncodeError):
        return None
```

The detector and peeler need to attempt decoding without crashing if the input is invalid. `try_decode` wraps `decode` and converts exceptions to `None`. The exception tuple covers all possible decode failures across all formats. This is the "errors as values" pattern, common in functional programming.

## detector.py — Confidence Scoring

### DetectionResult (line 24)

```python
@dataclass(frozen=True, slots=True)
class DetectionResult:
    format: EncodingFormat
    confidence: float
    decoded: bytes | None
```

Every detection result carries its confidence as a float from 0.0 to 1.0. This is fundamentally different from a binary "is it base64? yes/no" check. A string like `CAFE` could be hex or base64. Confidence scoring lets the system say "it's 80% likely hex, 50% likely base64" and rank accordingly.

### Scorer Walkthrough: _score_base64 (lines 31–67)

This is the most nuanced scorer because base64's character set overlaps with other formats.

**Phase 1 — Quick rejection (lines 32–38)**:
- Strip whitespace
- Reject if shorter than 4 characters
- Reject if any character isn't in `BASE64_CHARSET`
- Reject if length isn't divisible by 4

These checks are cheap. If any fails, the function returns 0.0 immediately without attempting a decode.

**Phase 2 — Structural scoring (lines 40–58)**:
- Start at 0.4 (baseline for matching charset + length)
- +0.1 for valid padding (0, 1, or 2 `=` characters)
- +0.1 if `+` or `/` present (these distinguish base64 from hex/base32)
- +0.1 for mixed case (uppercase AND lowercase letters)
- -0.2 penalty if no uppercase and no special characters (`+`, `/`, `=`)
- +0.05 for length >= 8

That -0.2 penalty is critical. A hex string like `6132666338` contains only lowercase letters and digits. Without the penalty, it scores 0.4 + 0.1 (padding) + 0.05 (length) + 0.15 (decode) + 0.15 (printable) = 0.85 as base64. With the penalty: 0.65. Meanwhile the hex scorer gives it 0.80. Hex wins.

**Phase 3 — Decode validation (lines 60–66)**:
- Attempt actual base64 decode with `try_decode`
- If decode fails, return 0.0 (invalid base64 structure)
- +0.15 for successful decode
- +0.15 if decoded output is printable text

### The Hex vs Base64 Disambiguation Problem

This was the hardest detection challenge. Consider the hex string `6332566a636d563049484268655778765957513d` (which is hex-encoded `c2VjcmV0IHBheWxvYWQ=`, which is base64-encoded `secret payload`).

Every character in that hex string (`0-9`, `a-f`) is also a valid base64 character. The string's length happens to be divisible by 4. Without careful scoring, both formats get similar confidence.

The solution uses two signals:

1. **Mixed-case check in base64 scorer (lines 50–55)**: Hex strings are typically all lowercase or all uppercase. Base64 almost always has mixed case. If there's no uppercase and no special chars, base64 gets a -0.2 penalty.

2. **Consistent-case bonus in hex scorer (lines 154–156)**: If all alphabetic characters are the same case, hex gets a +0.1 bonus.

These two adjustments create reliable separation. The hex string scores ~0.80 for hex and ~0.50 for base64.

### _score_url (lines 174–192)

The URL scorer works differently from the others. Instead of checking a character set, it uses a regex to find `%XX` patterns:

```python
_URL_PATTERN = re.compile(r"%[0-9a-fA-F]{2}")
```

The confidence scales with the ratio of encoded characters to total length. A string that's 50% percent-encoded sequences gets a higher score than one with a single `%20`. This handles the spectrum from "mostly normal text with one encoded space" to "completely percent-encoded payload."

### detect_encoding (lines 206–223)

The orchestrator. Runs every scorer, filters by threshold, sorts by confidence descending. The caller gets a ranked list of all possible formats above 0.6 confidence.

`detect_best` (lines 226–228) is a convenience that returns just the top result.

## peeler.py — Recursive Layer Stripping

### The Core Loop (lines 33–73)

The peel function is iterative, not recursive. Each iteration:

1. Calls `detect_best(current_text)` to find the most likely format
2. Checks three break conditions: no detection, below threshold, decode returned None
3. Records a `PeelLayer` with the current depth, format, confidence, and previews
4. Decodes and tries to interpret the result as UTF-8

The UTF-8 check on line 65 is the natural stop condition. When you hit the original data (which might be binary), it won't be valid UTF-8, and the loop breaks. This also prevents the peeler from trying to "detect" encodings in binary garbage.

### Why Iterative Instead of Recursive

The function uses a `for` loop with `max_depth` instead of calling itself. In Python, recursive calls have overhead (new stack frames) and risk `RecursionError` for deep chains. An iterative approach with explicit loop state is cleaner and has a hard cap via `range(max_depth)`.

### PeelResult Design (line 26)

```python
@dataclass(frozen=True, slots=True)
class PeelResult:
    layers: tuple[PeelLayer, ...]
    final_output: bytes
    success: bool
```

`layers` is a tuple, not a list. Since the result is frozen, the layers shouldn't be mutable either. `final_output` is `bytes` rather than `str` because the final decoded content might be binary data. `success` is `True` if at least one layer was peeled, `False` if the input didn't look encoded at all.

## formatter.py — Terminal Output

### stderr for Rich, stdout for Data (line 19)

```python
console = Console(stderr=True)
```

All Rich output (panels, tables, color) goes to stderr. When the user pipes output (`b64tool decode "..." | other_tool`), only raw data hits stdout. The `is_piped()` check on line 22 controls this: piped mode writes raw strings, terminal mode writes Rich panels.

### Confidence Color Coding (lines 164–169)

```python
def _confidence_color(confidence: float) -> str:
    if confidence >= 0.9:
        return "green"
    if confidence >= 0.7:
        return "yellow"
    return "red"
```

Visual feedback in the peel output. Green means the tool is very confident about the detected format. Yellow means it's likely correct but there's some ambiguity. Red means the detection is marginal (just above the 0.6 threshold).

## cli.py — Wiring It Together

### Typer Application (lines 39–45)

```python
app = typer.Typer(
    name="b64tool",
    help="Multi-format encoding/decoding CLI with recursive layer detection",
    no_args_is_help=True,
    pretty_exceptions_show_locals=False,
)
```

`no_args_is_help=True` shows the help message when the user runs `b64tool` with no subcommand. `pretty_exceptions_show_locals=False` prevents Typer from dumping local variables on crash, which could expose sensitive data being encoded/decoded.

### Annotated Type Hints (throughout)

Every CLI argument and option uses `Annotated[type, typer.Option(...)]`. This is the modern Typer pattern (replacing the older `typer.Option(default, ...)` style). The type annotation and CLI metadata stay together, and mypy validates the types correctly.

### Chain Step Parsing (lines 264–281)

```python
def _parse_chain_steps(raw: str) -> list[EncodingFormat]:
```

Parses `"base64,hex,url"` into `[EncodingFormat.BASE64, EncodingFormat.HEX, EncodingFormat.URL]`. Each step is stripped, lowercased, and validated against the enum. Invalid format names produce a clear error listing all valid options. This is a private function (prefixed with `_`) because it's implementation detail of the chain command.

## utils.py — Input Resolution

### Three Input Sources (lines 12–43)

Both `resolve_input_bytes` and `resolve_input_text` follow the same priority:

1. **File** (`--file` flag): Read from disk
2. **Argument**: Direct string on the command line
3. **Stdin**: Piped input (only if stdin is not a TTY)
4. If none: raise `typer.BadParameter`

This means these all work:
```bash
b64tool encode "Hello"
b64tool encode --file data.txt
echo "Hello" | b64tool encode
```

The distinction between bytes and text matters. Encoding operates on bytes (you can encode a binary file). Decoding operates on text (the encoded string is always ASCII-safe). This is why there are two separate functions rather than one generic one.

### is_printable_text (lines 60–68)

Used by the detector to boost confidence when decoded output looks like readable text. The threshold (default 0.8) means at least 80% of characters must be printable or common whitespace (`\n`, `\r`, `\t`). This prevents binary data that happens to decode without errors from getting a "printable text" bonus.
