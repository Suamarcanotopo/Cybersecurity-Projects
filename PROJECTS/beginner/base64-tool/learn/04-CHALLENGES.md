# Challenges

## Easy

### 1. Add ROT13 Encoding

ROT13 shifts each letter by 13 positions. It's a Caesar cipher with a fixed key that's its own inverse (encoding and decoding are the same operation).

**What to do:**
- Add `ROT13 = "rot13"` to `EncodingFormat` in `constants.py`
- Write `encode_rot13(data: bytes) -> str` and `decode_rot13(data: str) -> bytes` in `encoders.py`
- Add the entry to `ENCODER_REGISTRY`
- Write a scorer `_score_rot13` in `detector.py` (hint: try decoding and check if the result has more recognizable English words than the input)
- Add tests

**Why this matters:** ROT13 is trivial to implement but the detection scorer is tricky. How do you distinguish ROT13 text from plain ASCII text? Both use the same character set. You'll need a language-level heuristic (letter frequency analysis, common word matching).

### 2. Add JSON Output Mode

Currently output is either Rich panels or raw text. Add a `--json` flag that outputs structured JSON.

**What to do:**
- Add a `--json` / `-j` flag to the `detect` and `peel` commands in `cli.py`
- When active, serialize `DetectionResult` and `PeelResult` to JSON and write to stdout
- Skip Rich formatting entirely in JSON mode

**Example output:**
```json
{
  "results": [
    {
      "format": "base64",
      "confidence": 0.95,
      "decoded_preview": "Hello World"
    }
  ]
}
```

**Why this matters:** Machine-readable output is essential for integrating CLI tools into automated pipelines. Security automation workflows (SOAR, SIEM correlation) consume JSON, not colored terminal text.

### 3. Add `--output` File Flag

Add a `-o` / `--output` flag to write results directly to a file instead of stdout.

**What to do:**
- Add the option to `encode`, `decode`, and `peel` commands
- For encode/decode, write the raw result to the file
- For peel, write the final output
- Print a confirmation message to stderr

**Why this matters:** When decoding binary payloads (malware samples, images), you need the exact bytes written to disk, not a terminal preview.

---

## Medium

### 4. Add ASCII85 (Base85) Encoding

ASCII85 encodes 4 bytes into 5 characters using 85 printable ASCII characters. It's used in PDF files and Git binary patches.

**What to do:**
- Add `ASCII85 = "ascii85"` to `EncodingFormat`
- Use `base64.a85encode()` and `base64.a85decode()` from Python's standard library
- Write a scorer for detection (ASCII85 data has a distinctive character distribution, often includes characters like `!`, `@`, `#` that don't appear in other encodings)
- Handle the `<~...~>` wrapper that Adobe's variant uses

**Why this matters:** You'll encounter ASCII85 in PDF malware analysis. Malicious PDFs embed executable content using ASCII85 streams.

### 5. Decode-Chain Command (Reverse of Chain)

The `chain` command encodes through multiple layers. Build a `decode-chain` command that takes a chain specification and decodes in reverse order.

**What to do:**
- Add a `decode-chain` command to `cli.py`
- Accept `--steps` like the chain command
- Apply decoders in reverse order: `--steps base64,hex` decodes hex first, then base64
- Show each intermediate step

**Example:**
```bash
b64tool decode-chain "4147567362473873" --steps base64,hex
# Step 1: hex decode → "AGVsbG8s"
# Step 2: base64 decode → "Hello,"
```

**Why this matters:** When you know the encoding order from analysis (or from the `peel` output), you can verify by explicitly specifying the decode chain. This is useful for validating peel results.

### 6. Hex Dump Display

Add a `hexdump` command that shows decoded binary data in traditional hex dump format (offset, hex bytes, ASCII representation).

**What to do:**
- Add a `hexdump` command that takes encoded input and a format flag
- Decode the input, then display in hex dump format:
  ```
  00000000  48 65 6c 6c 6f 20 57 6f  72 6c 64 21 0a 00 ff fe  |Hello World!....|
  ```
- 16 bytes per line, offset on the left, ASCII on the right (non-printable as `.`)

**Why this matters:** Hex dump is the standard view for binary analysis. Malware analysts live in hex dump views. Combining decode + hexdump in one tool saves piping through `xxd` or `hexdump`.

---

## Hard

### 7. Custom Base64 Alphabet Support

The DARKGATE malware uses custom base64 alphabets to evade detection tools that only understand RFC 4648. Build support for encoding/decoding with arbitrary alphabets.

**What to do:**
- Add a `--alphabet` option to encode and decode commands
- Accept a 64-character string (or 65 with padding character)
- Implement custom alphabet encode/decode without relying on Python's `base64` module (it doesn't support custom alphabets directly)
- The encoding logic: take 3 bytes, split into four 6-bit values, map each to the custom alphabet
- Add a `--alphabet-file` option for reading the alphabet from a file

**Example:**
```bash
b64tool encode "secret" --format base64 --alphabet "ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvutsrqponmlkjihgfedcba9876543210+/"
```

**Why this matters:** Real malware uses this. Building it teaches you the actual encoding math (bit manipulation, not just calling library functions). Threat intelligence teams need tools that handle non-standard alphabets.

### 8. Encoding Frequency Analysis

Add an `analyze` command that takes a file of encoded samples and reports statistics.

**What to do:**
- Read a file where each line is an encoded sample
- Run detection on every line
- Report: format distribution, average confidence per format, detection failures
- Flag samples that match multiple formats (ambiguous detections)
- Output as a summary table and optionally as JSON

**Why this matters:** SOC analysts often receive bulk indicators (IOCs) and need to quickly categorize them. Is this list of strings mostly base64 tokens? Hex hashes? Mixed? Bulk analysis answers that.

### 9. Streaming Mode for Large Files

Currently the tool reads entire files into memory. Add streaming support for large file processing.

**What to do:**
- For base64 encoding: read 3 bytes at a time (produces 4 output chars), or buffer in multiples of 3
- For base64 decoding: read 4 characters at a time
- For hex: read 1 byte / 2 characters at a time
- Implement with generators to maintain constant memory usage
- Add a `--stream` flag or auto-detect based on file size

**Why this matters:** Memory-mapping a 2 GB file to base64 encode it will crash most systems. Streaming processes any file size with constant memory. This is how production tools like `base64` (coreutils) work.

---

## Expert

### 10. Binary Format Detection in Decoded Output

After decoding, automatically detect what the decoded binary data is (file type magic bytes).

**What to do:**
- After decode or peel, check the first few bytes against known magic numbers:
  - `\x89PNG\r\n\x1a\n` → PNG image
  - `PK\x03\x04` → ZIP/DOCX/JAR archive
  - `\x7fELF` → ELF executable (Linux binary)
  - `MZ` → PE executable (Windows binary)
  - `%PDF` → PDF document
  - `GIF87a` / `GIF89a` → GIF image
- Display the detected file type alongside the decoded output
- Optionally save to a file with the correct extension

**Why this matters:** Malware payloads are often base64-encoded executables. Knowing that a decoded blob is a PE executable versus a PNG image changes your entire analysis approach. The DARKGATE loader encodes its second-stage payload in custom base64 — the decoded output is a DLL.

### 11. Entropy Analysis

Add an `entropy` command that calculates Shannon entropy of data before and after decoding.

**What to do:**
- Calculate Shannon entropy: `H = -Σ p(x) log2(p(x))` for each byte value
- Report entropy on a 0–8 scale (8 bits per byte = maximum entropy)
- Compare entropy before and after decoding
- Flag high-entropy decoded output (likely encrypted or compressed, not just encoded)

**Interpretation guide:**
- 0–1: highly structured/repetitive (like all zeros)
- 3–5: English text, source code
- 6–7: compressed data, some binary formats
- 7.5–8: encrypted data, random bytes

**Why this matters:** If you peel 3 encoding layers and the output has entropy 7.9, it's almost certainly encrypted — further encoding analysis won't help. If entropy is 4.5, it's probably readable text. Entropy is the first triage check in malware analysis.

### 12. Integrate with CyberChef Recipes

CyberChef (GCHQ's open-source data analysis tool) uses "recipes" — JSON descriptions of operation chains. Build import/export compatibility.

**What to do:**
- Parse CyberChef recipe JSON format
- Map CyberChef operations to b64tool formats (e.g., "To Base64" → base64 encode)
- Execute a recipe as a chain command
- Export peel results as a CyberChef recipe (reverse operations)

**Example:**
```bash
b64tool recipe --import recipe.json "input data"
b64tool peel "encoded_data" --export-recipe result.json
```

**Why this matters:** CyberChef is ubiquitous in CTF competitions and security operations centers. Being able to exchange recipes between tools demonstrates real interoperability. It also means your tool can leverage the thousands of existing CyberChef recipes shared by the community.
