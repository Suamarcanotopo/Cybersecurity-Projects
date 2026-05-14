"""
©AngelaMos | 2026
peeler.py

Recursive multi-layer encoding detection and decoding

Iteratively calls detect_best() on the current text, decodes one
layer at a time, and continues until no encoding is detected, the
decoded output is not valid UTF-8, or max_depth is reached. Each
iteration produces a PeelLayer record capturing the format, confidence,
and previews. The complete result is returned as an immutable PeelResult.

Key exports:
  PeelLayer - Frozen dataclass for a single decoded layer (depth, format, confidence, previews)
  PeelResult - Frozen dataclass with all layers, final bytes output, and success flag
  peel() - Main entry point for recursive decoding

Connects to:
  constants.py - imports PEEL_MAX_DEPTH, CONFIDENCE_THRESHOLD, EncodingFormat
  detector.py - imports detect_best, score_all_formats
  utils.py - imports safe_bytes_preview, truncate
  formatter.py - imports PeelResult
  cli.py - imports peel
  test_peeler.py - tests single and multi-layer peeling
"""

from dataclasses import dataclass

from base64_tool.constants import (
    CONFIDENCE_THRESHOLD,
    PEEL_MAX_DEPTH,
    EncodingFormat,
)
from base64_tool.detector import detect_best, score_all_formats
from base64_tool.utils import safe_bytes_preview, truncate


@dataclass(frozen = True, slots = True)
class PeelLayer:
    depth: int
    format: EncodingFormat
    confidence: float
    encoded_preview: str
    decoded_preview: str
    all_scores: tuple[tuple[EncodingFormat, float], ...] = ()


@dataclass(frozen = True, slots = True)
class PeelResult:
    layers: tuple[PeelLayer, ...]
    final_output: bytes
    success: bool


def peel(
    data: str,
    *,
    max_depth: int = PEEL_MAX_DEPTH,
    threshold: float = CONFIDENCE_THRESHOLD,
    verbose: bool = False,
) -> PeelResult:
    layers: list[PeelLayer] = []
    current_text = data
    current_bytes = data.encode("utf-8")

    for depth in range(max_depth):
        detection = detect_best(current_text)

        if detection is None:
            break
        if detection.confidence < threshold:
            break
        if detection.decoded is None:
            break

        scores = (tuple(score_all_formats(current_text).items()) if verbose else ())

        decoded_bytes = detection.decoded
        layer = PeelLayer(
            depth = depth + 1,
            format = detection.format,
            confidence = detection.confidence,
            encoded_preview = truncate(current_text),
            decoded_preview = safe_bytes_preview(decoded_bytes),
            all_scores = scores,
        )
        layers.append(layer)
        current_bytes = decoded_bytes

        try:
            current_text = decoded_bytes.decode("utf-8")
        except (UnicodeDecodeError, ValueError):
            break

    return PeelResult(
        layers = tuple(layers),
        final_output = current_bytes,
        success = len(layers) > 0,
    )
