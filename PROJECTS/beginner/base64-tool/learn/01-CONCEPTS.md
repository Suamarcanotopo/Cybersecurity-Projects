# Concepts

## Encoding vs. Encryption

This is the single most important concept in this project, and confusing them causes real vulnerabilities.

**Encoding** transforms data into a different representation. Anyone can reverse it. There is no secret key. Base64 encoding is as "secure" as writing something in pig latin.

**Encryption** transforms data using a secret key. Without the key, you can't get the original back. AES, RSA, ChaCha20. These are encryption.

CWE-261 (Weak Encoding for Password) exists specifically because developers store passwords with base64 "encryption" instead of actual hashing. In 2018, a D-Link camera (CVE-2017-8417) stored admin credentials in base64 on the device. Anyone with network access could decode them instantly.

The rule: if you can reverse it without a password or key, it's encoding. Encoding is for compatibility, not security.

## How Base64 Works

Base64 converts binary data into 64 printable ASCII characters. The alphabet is `A-Z`, `a-z`, `0-9`, `+`, `/`, with `=` for padding.

### The Encoding Process

1. Take the input bytes
2. Read them as a stream of bits
3. Split into groups of 6 bits (not 8)
4. Map each 6-bit value (0-63) to a character in the alphabet

Why 6 bits? Because 2^6 = 64, which gives exactly 64 possible values per character.

```
Input:    "Hi"
Bytes:    0x48 0x69
Binary:   01001000 01101001

Split into 6-bit groups:
010010 | 000110 | 1001xx

Pad the last group with zeros:
010010 | 000110 | 100100

Map to alphabet:
18 → S    6 → G    36 → k

Add padding (input was 2 bytes, need 1 pad):
Result: "SGk="
```

Three input bytes produce exactly four output characters. When the input isn't divisible by 3, you get `=` padding. One leftover byte gets `==`, two leftover bytes get `=`.

### Base64URL Variant

Standard base64 uses `+` and `/` which are special characters in URLs. Base64URL (RFC 4648 Section 5) replaces them:
- `+` becomes `-`
- `/` becomes `_`

JWTs use base64url. So do many API tokens. If you see `-` or `_` in what looks like base64, it's probably base64url.

### Size Overhead

Base64 converts 3 bytes into 4 characters. That's a 33% size increase. A 1 MB file becomes ~1.33 MB when base64 encoded. This matters for things like embedding images in HTML or sending attachments in email (which is exactly why base64 was invented for MIME).

## How Base32 Works

Same idea as base64, but uses only 32 characters: `A-Z` and `2-7`. Groups of 5 bits instead of 6.

Why would you use base32 over base64? Environments where case sensitivity is a problem. DNS names are case insensitive, so base64 doesn't work there. TOTP tokens (Google Authenticator) use base32 for the shared secret because humans might misread uppercase/lowercase when typing a key.

Base32 produces longer output than base64 (60% overhead vs 33%). The tradeoff is fewer possible characters means fewer ambiguity issues.

## Hexadecimal Encoding

Hex represents each byte as two characters from `0-9` and `a-f`. It's a direct byte-to-text mapping.

```
Input:    "Hi"
Bytes:    0x48 0x69
Hex:      4869
```

100% size overhead (every byte becomes two characters), but it's the most straightforward encoding and universally readable. You see hex in:
- MAC addresses: `aa:bb:cc:dd:ee:ff`
- Color codes: `#FF5733`
- Packet captures and hex dumps
- Malware hash signatures: `d41d8cd98f00b204e9800998ecf8427e`
- Binary file analysis

## URL Encoding (Percent Encoding)

URLs have reserved characters (`?`, `&`, `=`, `/`, `#`, etc.) that have special meaning. URL encoding replaces unsafe characters with `%XX` where `XX` is the hex value.

```
Input:    "hello world&key=val"
Encoded:  "hello%20world%26key%3Dval"
```

Space is `%20` in standard URL encoding but `+` in form encoding (`application/x-www-form-urlencoded`). The distinction matters for web security testing.

## RFC 4648

RFC 4648 is the definitive standard for Base16, Base32, and Base64 encoding. Key points:

- Defines the exact alphabets and padding rules
- Specifies when decoders MUST reject vs MAY accept malformed input
- Base64 padding is `=`, and it MUST appear only at the end
- Decoders that accept non-alphabet characters create security issues (padding oracle attacks become possible)

Python's `base64` module follows RFC 4648. The `validate=True` parameter in `b64decode` enforces strict compliance, rejecting any non-alphabet characters. This project uses strict decoding.

## Encoding in Attacks

### Double Encoding (WAF Bypass)

Web Application Firewalls (WAFs) check request parameters for malicious content. If you URL-encode a payload, the WAF decodes it once and checks. But what if you double-encode?

```
Payload:    <script>alert(1)</script>
Single:     %3Cscript%3Ealert(1)%3C/script%3E    ← WAF catches this
Double:     %253Cscript%253Ealert(1)%253C/script%253E  ← WAF decodes once,
            sees %3C (looks harmless), passes it through
```

The web server decodes again, and the browser gets the original XSS payload. This is OWASP's A05:2025 Injection category. Double encoding still works against poorly configured WAFs in 2026.

### Multi-Layer Obfuscation (Malware)

The DARKGATE malware (actively sold on dark web forums) encodes its configuration and keylogger output using a custom, non-standard base64 alphabet. Older versions used a hardcoded custom alphabet. Version 5.2.3+ randomizes the alphabet based on a hardware ID seed.

Researchers at Kroll found a weakness: the hardware ID is a 32-byte ASCII MD5 hash, and DARKGATE sums these bytes as a seed. The sum has limited entropy, making brute-force recovery of the custom alphabet feasible.

This is why understanding encoding matters for security: real malware uses real encoding tricks, and analysts need to decode them.

### Data Exfiltration

Attackers exfiltrate data by encoding it and embedding it in seemingly normal traffic:
- Base64 data in DNS TXT record queries
- Hex-encoded payloads in HTTP headers
- URL-encoded data in query parameters that look like analytics tracking

Tools like this one help defenders spot and decode these patterns.

## Encoding Detection

How do you figure out what encoding something is? Pattern matching and heuristics.

**Base64 signals:**
- Characters from `A-Za-z0-9+/=`
- Length divisible by 4
- Ends with 0, 1, or 2 `=` characters
- Mixed case (uppercase AND lowercase letters)

**Base32 signals:**
- All uppercase `A-Z` and digits `2-7`
- Length divisible by 8
- Padding with 0, 1, 3, 4, or 6 `=` characters

**Hex signals:**
- Only `0-9` and `a-f` (or `A-F`)
- Even length
- Consistent casing (all lower or all upper)
- Sometimes has separators (`:`, `-`, spaces)

**URL encoding signals:**
- Contains `%XX` sequences where XX is valid hex

The tricky part: some strings match multiple formats. The hex string `CAFE` is also valid base32 (if padded to 8 chars) and base64 (if length works out). Good detection uses confidence scoring, not binary yes/no. This project assigns each format a confidence from 0.0 to 1.0 and ranks them.

## Testing Your Understanding

1. Why does base64 output always have a length divisible by 4?
2. A developer stores API keys as base64 in a config file and calls it "encrypted configuration." What's wrong?
3. You see the string `JBSWY3DPEBLW64TMMQ======`. What encoding is this and how can you tell?
4. An IDS alert shows `%253Cscript%253E` in a URL parameter. What happened?
5. Why would malware use a non-standard base64 alphabet instead of the RFC 4648 one?
