"""
©AngelaMos | 2026
utils.py

Input resolution and string/bytes utility functions

Handles the three input sources the CLI accepts: a positional
argument, a --file path, or piped stdin. Also provides truncate()
for capping display strings, safe_bytes_preview() for converting
raw bytes to a readable preview, and is_printable_text() for
checking whether decoded bytes look like human-readable output.

Key exports:
  resolve_input_bytes() - Returns raw bytes from argument, file, or stdin
  resolve_input_text() - Returns decoded text from argument, file, or stdin
  truncate() - Truncates a string with "..." if it exceeds the length limit
  safe_bytes_preview() - Converts bytes to UTF-8 string or hex fallback
  is_printable_text() - Returns True if bytes decode to mostly printable characters

Connects to:
  detector.py - imports is_printable_text
  peeler.py - imports safe_bytes_preview, truncate
  formatter.py - imports safe_bytes_preview
  cli.py - imports resolve_input_bytes, resolve_input_text
"""

import sys
from pathlib import Path

import typer


def resolve_input_bytes(
    data: str | None,
    file: Path | None,
) -> bytes:
    if file is not None:
        if not file.exists():
            raise typer.BadParameter(f"File not found: {file}")
        return file.read_bytes()
    if data is not None:
        return data.encode("utf-8")
    if not sys.stdin.isatty():
        return sys.stdin.buffer.read()
    raise typer.BadParameter(
        "No input provided. Pass an argument, use --file, or pipe stdin."
    )


def resolve_input_text(
    data: str | None,
    file: Path | None,
) -> str:
    if file is not None:
        if not file.exists():
            raise typer.BadParameter(f"File not found: {file}")
        return file.read_text("utf-8").strip()
    if data is not None:
        return data.strip()
    if not sys.stdin.isatty():
        return sys.stdin.read().strip()
    raise typer.BadParameter(
        "No input provided. Pass an argument, use --file, or pipe stdin."
    )


def truncate(text: str, length: int = 72) -> str:
    if len(text) <= length:
        return text
    return text[: length] + "..."


def safe_bytes_preview(data: bytes, length: int = 72) -> str:
    try:
        text = data.decode("utf-8")
        return truncate(text, length)
    except (UnicodeDecodeError, ValueError):
        return truncate(data.hex(), length)


def is_printable_text(data: bytes, threshold: float = 0.8) -> bool:
    try:
        text = data.decode("utf-8")
    except (UnicodeDecodeError, ValueError):
        return False
    if not text:
        return False
    printable_count = sum(1 for c in text if c.isprintable() or c in "\n\r\t")
    return (printable_count / len(text)) >= threshold
