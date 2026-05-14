"""
©AngelaMos | 2026
constants.py

Encoding format definitions, scoring weights, and shared constants

Defines the EncodingFormat and ExitCode enums, numeric thresholds
used by the detector (confidence, printable ratio, min input length),
character set frozensets for charset membership tests, and the
ScoreWeight class that holds every per-format confidence score
contribution. All values shared across the package live here.

Key exports:
  EncodingFormat - StrEnum of supported formats (base64, base64url, base32, hex, url)
  ExitCode - CLI exit codes for success, error, and invalid input
  ScoreWeight - Per-format scoring weights used by detector.py
  BASE64_CHARSET, BASE64URL_CHARSET, BASE32_CHARSET, HEX_CHARSET - Valid character sets
  CONFIDENCE_THRESHOLD, PEEL_MAX_DEPTH, PREVIEW_LENGTH - Shared thresholds

Connects to:
  encoders.py - imports EncodingFormat
  detector.py - imports EncodingFormat, ScoreWeight, charsets, thresholds
  peeler.py - imports EncodingFormat, PEEL_MAX_DEPTH, CONFIDENCE_THRESHOLD
  formatter.py - imports EncodingFormat, CONFIDENCE_THRESHOLD, PREVIEW_LENGTH
  cli.py - imports EncodingFormat, ExitCode, PEEL_MAX_DEPTH
"""

from enum import StrEnum
from typing import Final


class EncodingFormat(StrEnum):
    BASE64 = "base64"
    BASE64URL = "base64url"
    BASE32 = "base32"
    HEX = "hex"
    URL = "url"


class ExitCode:
    SUCCESS: Final[int] = 0
    ERROR: Final[int] = 1
    INVALID_INPUT: Final[int] = 2


PEEL_MAX_DEPTH: Final[int] = 20

MIN_INPUT_LENGTH: Final[int] = 4

PREVIEW_LENGTH: Final[int] = 72

CONFIDENCE_THRESHOLD: Final[float] = 0.6

PRINTABLE_RATIO_THRESHOLD: Final[float] = 0.8


class ScoreWeight:
    DECODE_SUCCESS: Final[float] = 0.15
    PRINTABLE_RESULT: Final[float] = 0.15
    LONGER_INPUT: Final[float] = 0.05

    B64_BASE: Final[float] = 0.4
    B64_VALID_PADDING: Final[float] = 0.1
    B64_SPECIAL_CHARS: Final[float] = 0.1
    B64_MIXED_CASE: Final[float] = 0.1
    B64_NO_SIGNAL_PENALTY: Final[float] = 0.2

    B64URL_BASE: Final[float] = 0.3
    B64URL_SAFE_CHARS: Final[float] = 0.25

    B32_BASE: Final[float] = 0.35
    B32_VALID_PADDING: Final[float] = 0.1
    B32_UPPERCASE: Final[float] = 0.1

    HEX_BASE: Final[float] = 0.3
    HEX_SEPARATOR_PRESENT: Final[float] = 0.2
    HEX_ALPHA_CHARS: Final[float] = 0.1
    HEX_NO_ALPHA_PENALTY: Final[float] = 0.15
    HEX_CONSISTENT_CASE: Final[float] = 0.1
    HEX_DECODE_SUCCESS: Final[float] = 0.1

    URL_BASE: Final[float] = 0.3
    URL_RATIO_MULTIPLIER: Final[float] = 0.4
    URL_RATIO_CAP: Final[float] = 0.35
    URL_DECODE_CHANGED: Final[float] = 0.15


BASE64_CHARSET: Final[
    frozenset[str]
] = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")

BASE64URL_CHARSET: Final[
    frozenset[str]
] = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")

BASE32_CHARSET: Final[frozenset[str]] = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=")

HEX_CHARSET: Final[frozenset[str]] = frozenset("0123456789abcdefABCDEF")

HEX_SEPARATORS: Final[frozenset[str]] = frozenset(" :.-")
