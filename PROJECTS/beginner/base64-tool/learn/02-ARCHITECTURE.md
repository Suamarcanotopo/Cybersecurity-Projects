# Architecture

## Design Philosophy

Every module in this project has one job. `encoders.py` transforms data. `detector.py` scores formats. `peeler.py` orchestrates recursive decoding. `formatter.py` renders output. `cli.py` wires user input to functions. No module reaches into another module's concern.

This isn't over-engineering for a small project. It's how you keep a small project from becoming an unmanageable one. When you need to add a new encoding format, you touch `encoders.py` and `detector.py`. That's it. The CLI, formatter, and peeler don't change.

## Module Dependency Graph

```
cli.py
├── constants.py     (EncodingFormat, ExitCode, PEEL_MAX_DEPTH)
├── encoders.py      (encode, decode, encode_url, decode_url)
├── detector.py      (detect_encoding)
├── peeler.py        (peel)
├── formatter.py     (print_encoded, print_decoded, print_detection, print_peel_result, print_chain_result)
└── utils.py         (resolve_input_bytes, resolve_input_text)

peeler.py
├── constants.py     (CONFIDENCE_THRESHOLD, PEEL_MAX_DEPTH, EncodingFormat)
├── detector.py      (detect_best)
└── utils.py         (safe_bytes_preview, truncate)

detector.py
├── constants.py     (charsets, thresholds, EncodingFormat)
├── encoders.py      (try_decode)
└── utils.py         (is_printable_text)

formatter.py
├── constants.py     (EncodingFormat, PREVIEW_LENGTH)
├── detector.py      (DetectionResult — type only)
├── peeler.py        (PeelResult — type only)
└── utils.py         (safe_bytes_preview)

encoders.py
└── constants.py     (EncodingFormat)

utils.py
└── (no internal deps)

constants.py
└── (no internal deps)
```

The dependency arrows always point downward. `constants.py` and `utils.py` sit at the bottom with zero internal dependencies. `cli.py` sits at the top, importing from everything. Nothing in the middle reaches upward. This is a directed acyclic graph (DAG), and if you ever create a circular import, Python will tell you immediately.

## Data Flow

### Encode Command

```
User Input (str or file or stdin)
    │
    ▼
resolve_input_bytes()          ← utils.py:12
    │  Converts any input source to raw bytes
    ▼
encode(raw, fmt)               ← encoders.py:88
    │  Dispatches via ENCODER_REGISTRY to format-specific function
    ▼
encode_base64(data) (or other) ← encoders.py:22
    │  Returns encoded string
    ▼
print_encoded(result, fmt)     ← formatter.py:31
    │  Rich panel if terminal, raw stdout if piped
    ▼
Output
```

### Decode Command

```
User Input (str or file or stdin)
    │
    ▼
resolve_input_text()           ← utils.py:29
    │  Converts any input source to stripped text
    ▼
decode(text, fmt)              ← encoders.py:93
    │  Dispatches via ENCODER_REGISTRY to format-specific function
    ▼
decode_base64(data) (or other) ← encoders.py:26
    │  Returns decoded bytes
    ▼
print_decoded(result)          ← formatter.py:44
    │  Safe preview (UTF-8 if possible, hex fallback)
    ▼
Output
```

### Detect Command

```
User Input (str)
    │
    ▼
detect_encoding(text)          ← detector.py:206
    │
    ├──► _score_base64(text)   ← detector.py:31
    ├──► _score_base64url(text)← detector.py:70
    ├──► _score_base32(text)   ← detector.py:97
    ├──► _score_hex(text)      ← detector.py:126
    └──► _score_url(text)      ← detector.py:174
    │
    │  Each scorer returns 0.0–1.0
    │  Results filtered by CONFIDENCE_THRESHOLD (0.6)
    │  Sorted by confidence descending
    ▼
print_detection(results)       ← formatter.py:58
    │  Rich table: format, confidence %, decoded preview
    ▼
Output
```

### Peel Command (the star feature)

```
User Input (str)
    │
    ▼
peel(text, max_depth=20)       ← peeler.py:33
    │
    ├──► LOOP (up to max_depth iterations):
    │    │
    │    ├── detect_best(current_text)  ← detector.py:226
    │    │   Returns highest-confidence detection
    │    │
    │    ├── Break if: no detection, below threshold, decode fails
    │    │
    │    ├── Record PeelLayer (depth, format, confidence, previews)
    │    │
    │    └── decoded_bytes → current_text for next iteration
    │        (break if bytes aren't valid UTF-8)
    │
    ▼
PeelResult(layers, final_output, success)
    │
    ▼
print_peel_result(result)      ← formatter.py:94
    │  Layer-by-layer display + final output panel
    ▼
Output
```

### Chain Command

```
User Input (str) + --steps "base64,hex,url"
    │
    ▼
resolve_input_bytes()          ← utils.py:12
    │
    ▼
_parse_chain_steps("base64,hex,url")  ← cli.py:264
    │  Validates each format name against EncodingFormat enum
    │  Returns [BASE64, HEX, URL]
    ▼
LOOP over formats:
    │
    ├── encode(current_bytes, fmt)     ← encoders.py:88
    ├── Record (fmt, encoded_string)
    └── encoded_string → bytes for next iteration
    │
    ▼
print_chain_result(steps, final)       ← formatter.py:130
    │  Step-by-step display + final panel
    ▼
Output
```

## Key Patterns

### Registry Pattern (encoders.py:73–85)

Instead of a chain of `if fmt == "base64": ... elif fmt == "base64url": ...`, every encoder and decoder pair is registered in a dictionary:

```
ENCODER_REGISTRY: dict[EncodingFormat, tuple[EncoderFn, DecoderFn]]
```

Adding a new format means adding one entry to the registry and writing the two functions. The dispatch functions `encode()` and `decode()` never change. This is the open-closed principle: open for extension, closed for modification.

### Frozen Dataclasses (detector.py:24, peeler.py:17, peeler.py:26)

All result types use `@dataclass(frozen=True, slots=True)`. Frozen means the fields can't be mutated after creation. Slots means no `__dict__` per instance, which uses less memory and is slightly faster. For data that flows through a pipeline and should never be changed, frozen dataclasses are the right tool.

### Pipeline-Friendly Output (formatter.py:22–28)

The tool detects whether stdout is a terminal or a pipe. When piped (`echo "data" | b64tool decode | other_tool`), it writes raw text to stdout with no Rich formatting. When interactive, it shows panels, tables, and colors. This happens via `is_piped()` checking `sys.stdout.isatty()`.

Rich output goes to stderr (`Console(stderr=True)` at `formatter.py:19`), so diagnostic messages never contaminate piped data. This is a standard Unix convention that many CLI tools get wrong.

### Scorer Architecture (detector.py:195–203)

Detection uses the same registry pattern as encoding. Each format has a scorer function with the signature `Callable[[str], float]`. The `_SCORERS` dictionary maps `EncodingFormat` to its scorer. This means adding detection for a new format requires writing one scorer function and adding one dict entry.

Every scorer follows the same structure:
1. Quick rejection (charset check, length check)
2. Accumulate a confidence score based on structural signals
3. Attempt actual decoding
4. Bonus if decoded output is printable text
5. Return clamped to [0.0, 1.0]

### Type Aliases with PEP 695 (encoders.py:18–19)

```
type EncoderFn = Callable[[bytes], str]
type DecoderFn = Callable[[str], bytes]
```

Python 3.12+ `type` statements (PEP 695) replace `TypeAlias` from `typing`. They're lazily evaluated and more readable. These aliases document the contract: encoders take bytes and return strings, decoders take strings and return bytes.

## Error Handling Strategy

Errors are handled at two levels:

**Module level**: Functions like `try_decode()` (`encoders.py:98`) catch encoding-specific exceptions and return `None`. The detector and peeler use this to gracefully handle decode failures without crashing.

**CLI level**: Each command (`cli.py`) wraps its body in a try/except. `typer.BadParameter` is re-raised (Typer formats these nicely). All other exceptions get a `[red]Error:[/red]` message and exit code 1. This prevents stack traces from leaking to end users.

The intermediate modules (detector, peeler) never catch exceptions themselves. They call `try_decode()` and check for `None`. This keeps error handling at the boundaries, not scattered through business logic.

## Why Not a Class?

None of the core modules use classes for behavior (only for data: `EncodingFormat`, `DetectionResult`, `PeelLayer`, `PeelResult`). The encoder functions are pure functions. The scorers are pure functions. The peeler is a function. There's no shared mutable state to encapsulate, so there's no reason for a class.

An `Encoder` class with `encode()` and `decode()` methods would add indirection without adding value. The registry dict achieves the same polymorphism with less ceremony. This is idiomatic Python: use classes for data, functions for behavior, unless you have state to manage.
