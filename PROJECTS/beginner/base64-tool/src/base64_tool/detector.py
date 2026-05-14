"""
©AngelaMos | 2026
detector.py

Format detection via per-format confidence scoring

Runs each input string through five scoring functions (one per
supported format) that check charset membership, structural constraints
like padding alignment, and whether the decoded result is printable
text. Scores are clamped to [0.0, 1.0]. Results above
CONFIDENCE_THRESHOLD are returned as DetectionResult instances,
sorted by confidence descending.

Key exports:
  DetectionResult - Frozen dataclass with format, confidence, and decoded bytes
  detect_encoding() - Returns all formats that exceed the confidence threshold
  detect_best() - Returns the single highest-confidence result, or None
  score_all_formats() - Returns raw confidence scores for every format

Connects to:
  constants.py - imports charsets, thresholds, ScoreWeight, EncodingFormat
  encoders.py - imports try_decode
  utils.py - imports is_printable_text
  peeler.py - imports detect_best, score_all_formats
  formatter.py - imports DetectionResult
  cli.py - imports detect_encoding, score_all_formats
  test_detector.py - tests detection accuracy per format
"""

import re
from collections.abc import Callable
from dataclasses import dataclass

from base64_tool.constants import (
    BASE32_CHARSET,
    BASE64_CHARSET,
    BASE64URL_CHARSET,
    CONFIDENCE_THRESHOLD,
    EncodingFormat,
    HEX_CHARSET,
    HEX_SEPARATORS,
    MIN_INPUT_LENGTH,
    ScoreWeight as W,
)
from base64_tool.encoders import try_decode
from base64_tool.utils import is_printable_text


@dataclass(frozen = True, slots = True)
class DetectionResult:
    format: EncodingFormat
    confidence: float
    decoded: bytes | None


def _score_base64(data: str) -> float:
    stripped = "".join(data.split())
    if len(stripped) < MIN_INPUT_LENGTH:
        return 0.0
    if not all(c in BASE64_CHARSET for c in stripped):
        return 0.0
    if len(stripped) % 4 != 0:
        return 0.0

    score = W.B64_BASE
    content = stripped.rstrip("=")

    padding = len(stripped) - len(content)
    if padding <= 2:
        score += W.B64_VALID_PADDING

    if any(c in stripped for c in "+/"):
        score += W.B64_SPECIAL_CHARS

    has_upper = any(c.isupper() for c in content)
    has_lower = any(c.islower() for c in content)
    if has_upper and has_lower:
        score += W.B64_MIXED_CASE
    elif not has_upper and not any(c in stripped for c in "+/="):
        score -= W.B64_NO_SIGNAL_PENALTY

    if len(stripped) >= 8:
        score += W.LONGER_INPUT

    decoded = try_decode(stripped, EncodingFormat.BASE64)
    if decoded is None:
        return 0.0
    score += W.DECODE_SUCCESS
    if is_printable_text(decoded):
        score += W.PRINTABLE_RESULT

    return min(score, 1.0)


def _score_base64url(data: str) -> float:
    stripped = "".join(data.split())
    if len(stripped) < MIN_INPUT_LENGTH:
        return 0.0
    if not all(c in BASE64URL_CHARSET for c in stripped):
        return 0.0

    score = W.B64URL_BASE

    has_url_chars = any(c in stripped for c in "-_")
    has_std_chars = any(c in stripped for c in "+/")

    if has_url_chars and not has_std_chars:
        score += W.B64URL_SAFE_CHARS
    elif not has_url_chars:
        return 0.0

    decoded = try_decode(stripped, EncodingFormat.BASE64URL)
    if decoded is None:
        return 0.0
    score += W.DECODE_SUCCESS
    if is_printable_text(decoded):
        score += W.PRINTABLE_RESULT

    return min(score, 1.0)


def _score_base32(data: str) -> float:
    stripped = "".join(data.split()).upper()
    if len(stripped) < MIN_INPUT_LENGTH:
        return 0.0
    if not all(c in BASE32_CHARSET for c in stripped):
        return 0.0
    if len(stripped) % 8 != 0:
        return 0.0

    score = W.B32_BASE

    valid_pad_counts = frozenset({0, 1, 3, 4, 6})
    padding = len(stripped) - len(stripped.rstrip("="))
    if padding in valid_pad_counts:
        score += W.B32_VALID_PADDING

    if data == data.upper():
        score += W.B32_UPPERCASE

    decoded = try_decode(stripped, EncodingFormat.BASE32)
    if decoded is None:
        return 0.0
    score += W.DECODE_SUCCESS
    if is_printable_text(decoded):
        score += W.PRINTABLE_RESULT

    return min(score, 1.0)


def _score_hex(data: str) -> float:
    stripped = data.strip()
    if len(stripped) < MIN_INPUT_LENGTH:
        return 0.0

    hex_only = stripped
    for sep in HEX_SEPARATORS:
        hex_only = hex_only.replace(sep, "")

    if not hex_only:
        return 0.0
    if not all(c in HEX_CHARSET for c in hex_only):
        return 0.0
    if len(hex_only) % 2 != 0:
        return 0.0

    score = W.HEX_BASE

    has_separators = any(sep in stripped for sep in HEX_SEPARATORS)
    if has_separators:
        score += W.HEX_SEPARATOR_PRESENT

    has_alpha = any(c in "abcdefABCDEF" for c in hex_only)
    if has_alpha:
        score += W.HEX_ALPHA_CHARS
    else:
        score -= W.HEX_NO_ALPHA_PENALTY

    is_consistent_case = (hex_only == hex_only.lower() or hex_only == hex_only.upper())
    if is_consistent_case:
        score += W.HEX_CONSISTENT_CASE

    if len(hex_only) >= 8:
        score += W.LONGER_INPUT

    decoded = try_decode(stripped, EncodingFormat.HEX)
    if decoded is None:
        return 0.0
    score += W.HEX_DECODE_SUCCESS
    if is_printable_text(decoded):
        score += W.PRINTABLE_RESULT

    return min(score, 1.0)


_URL_PATTERN = re.compile(r"%[0-9a-fA-F]{2}")


def _score_url(data: str) -> float:
    if len(data) < MIN_INPUT_LENGTH:
        return 0.0

    matches = _URL_PATTERN.findall(data)
    if not matches:
        return 0.0

    encoded_char_count = len(matches) * 3
    ratio = encoded_char_count / len(data)
    score = W.URL_BASE + min(ratio * W.URL_RATIO_MULTIPLIER, W.URL_RATIO_CAP)

    decoded = try_decode(data, EncodingFormat.URL)
    if decoded is not None:
        decoded_text = decoded.decode("utf-8", errors = "replace")
        if decoded_text != data:
            score += W.URL_DECODE_CHANGED

    return min(score, 1.0)


_SCORERS: dict[EncodingFormat,
               Callable[[str],
                        float]] = {
                            EncodingFormat.BASE64: _score_base64,
                            EncodingFormat.BASE64URL: _score_base64url,
                            EncodingFormat.BASE32: _score_base32,
                            EncodingFormat.HEX: _score_hex,
                            EncodingFormat.URL: _score_url,
                        }


def score_all_formats(data: str) -> dict[EncodingFormat, float]:
    return {fmt: scorer(data) for fmt, scorer in _SCORERS.items()}


def detect_encoding(data: str) -> list[DetectionResult]:
    results: list[DetectionResult] = []

    for fmt, confidence in score_all_formats(data).items():
        if confidence >= CONFIDENCE_THRESHOLD:
            decoded = try_decode(data, fmt)
            results.append(
                DetectionResult(
                    format = fmt,
                    confidence = round(confidence,
                                       2),
                    decoded = decoded,
                )
            )

    results.sort(key = lambda r: r.confidence, reverse = True)
    return results


def detect_best(data: str) -> DetectionResult | None:
    results = detect_encoding(data)
    return results[0] if results else None
