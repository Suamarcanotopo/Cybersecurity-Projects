"""
©AngelaMos | 2026
cli.py

Typer CLI application with five encoding subcommands

Defines the b64tool Typer app and its five commands: encode, decode,
detect, peel, and chain. Each command resolves its input from a
positional argument, --file, or stdin, delegates to the appropriate
logic module, then passes results to formatter.py for display. The
chain command applies a comma-separated sequence of formats in order,
passing each encoded output as the next step's input.

Key exports:
  app - The Typer application instance registered as the CLI entry point

Connects to:
  __init__.py - imports __version__
  constants.py - imports EncodingFormat, ExitCode, PEEL_MAX_DEPTH
  encoders.py - imports encode, decode, encode_url, decode_url
  detector.py - imports detect_encoding, score_all_formats
  peeler.py - imports peel
  formatter.py - imports all print_* functions
  utils.py - imports resolve_input_bytes, resolve_input_text
  test_cli.py - exercises all commands via Typer's CliRunner
"""

from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console

from base64_tool import __version__
from base64_tool.constants import (
    EncodingFormat,
    ExitCode,
    PEEL_MAX_DEPTH,
)
from base64_tool.detector import detect_encoding, score_all_formats
from base64_tool.encoders import (
    decode,
    encode,
    encode_url,
    decode_url,
)
from base64_tool.formatter import (
    print_chain_result,
    print_decoded,
    print_detection,
    print_encoded,
    print_peel_result,
)
from base64_tool.peeler import peel
from base64_tool.utils import (
    resolve_input_bytes,
    resolve_input_text,
)


app = typer.Typer(
    name = "b64tool",
    help = ("Multi-format encoding/decoding CLI "
            "with recursive layer detection"),
    no_args_is_help = True,
    pretty_exceptions_show_locals = False,
)

_console = Console(stderr = True)


def _version_callback(value: bool) -> None:
    if value:
        _console.print(f"b64tool v{__version__}")
        raise typer.Exit()


@app.callback()
def main(
    version: Annotated[
        bool,
        typer.Option(
            "--version",
            "-v",
            help = "Show version and exit.",
            callback = _version_callback,
            is_eager = True,
        ),
    ] = False,
) -> None:
    pass


@app.command(name = "encode")
def encode_cmd(
    data: Annotated[
        str | None,
        typer.Argument(help = "Data to encode."),
    ] = None,
    fmt: Annotated[
        EncodingFormat,
        typer.Option(
            "--format",
            "-f",
            help = "Target encoding format.",
        ),
    ] = EncodingFormat.BASE64,
    file: Annotated[
        Path | None,
        typer.Option(
            "--file",
            "-i",
            help = "Read input from file.",
        ),
    ] = None,
    form: Annotated[
        bool,
        typer.Option(
            "--form",
            help = "Use form-encoding for URL (space becomes +).",
        ),
    ] = False,
) -> None:
    try:
        raw = resolve_input_bytes(data, file)
        if fmt == EncodingFormat.URL and form:
            result = encode_url(raw, form = True)
        else:
            result = encode(raw, fmt)
        print_encoded(result, fmt)
    except typer.BadParameter:
        raise
    except Exception as exc:
        _console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code = ExitCode.ERROR) from None


@app.command(name = "decode")
def decode_cmd(
    data: Annotated[
        str | None,
        typer.Argument(help = "Data to decode."),
    ] = None,
    fmt: Annotated[
        EncodingFormat,
        typer.Option(
            "--format",
            "-f",
            help = "Source encoding format.",
        ),
    ] = EncodingFormat.BASE64,
    file: Annotated[
        Path | None,
        typer.Option(
            "--file",
            "-i",
            help = "Read input from file.",
        ),
    ] = None,
    form: Annotated[
        bool,
        typer.Option(
            "--form",
            help = "Use form-decoding for URL (+ becomes space).",
        ),
    ] = False,
) -> None:
    try:
        text = resolve_input_text(data, file)
        if fmt == EncodingFormat.URL and form:
            result = decode_url(text, form = True)
        else:
            result = decode(text, fmt)
        print_decoded(result)
    except typer.BadParameter:
        raise
    except Exception as exc:
        _console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code = ExitCode.ERROR) from None


@app.command(name = "detect")
def detect_cmd(
    data: Annotated[
        str | None,
        typer.Argument(help = "Data to analyze."),
    ] = None,
    file: Annotated[
        Path | None,
        typer.Option(
            "--file",
            "-i",
            help = "Read input from file.",
        ),
    ] = None,
    verbose: Annotated[
        bool,
        typer.Option(
            "--verbose",
            "-V",
            help = "Show per-format score breakdown.",
        ),
    ] = False,
) -> None:
    try:
        text = resolve_input_text(data, file)
        results = detect_encoding(text)
        scores = score_all_formats(text) if verbose else None
        print_detection(results, verbose_scores = scores)
    except typer.BadParameter:
        raise
    except Exception as exc:
        _console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code = ExitCode.ERROR) from None


@app.command(name = "peel")
def peel_cmd(
    data: Annotated[
        str | None,
        typer.Argument(help = "Data to recursively decode."),
    ] = None,
    file: Annotated[
        Path | None,
        typer.Option(
            "--file",
            "-i",
            help = "Read input from file.",
        ),
    ] = None,
    max_depth: Annotated[
        int,
        typer.Option(
            "--max-depth",
            "-d",
            help = "Maximum decoding layers.",
        ),
    ] = PEEL_MAX_DEPTH,
    verbose: Annotated[
        bool,
        typer.Option(
            "--verbose",
            "-V",
            help = "Show per-format score breakdown at each layer.",
        ),
    ] = False,
) -> None:
    try:
        text = resolve_input_text(data, file)
        result = peel(text, max_depth = max_depth, verbose = verbose)
        print_peel_result(result, verbose = verbose)
    except typer.BadParameter:
        raise
    except Exception as exc:
        _console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code = ExitCode.ERROR) from None


@app.command(name = "chain")
def chain_cmd(
    data: Annotated[
        str | None,
        typer.Argument(help = "Data to encode through chain."),
    ] = None,
    steps: Annotated[
        str,
        typer.Option(
            "--steps",
            "-s",
            help = ("Comma-separated encoding formats "
                    "(e.g. base64,hex,url)."),
        ),
    ] = "base64",
    file: Annotated[
        Path | None,
        typer.Option(
            "--file",
            "-i",
            help = "Read input from file.",
        ),
    ] = None,
) -> None:
    try:
        raw = resolve_input_bytes(data, file)
        formats = _parse_chain_steps(steps)
        intermediates: list[tuple[EncodingFormat, str]] = []
        current = raw

        for step_fmt in formats:
            encoded = encode(current, step_fmt)
            intermediates.append((step_fmt, encoded))
            current = encoded.encode("utf-8")

        final = intermediates[-1][1] if intermediates else ""
        print_chain_result(intermediates, final)
    except typer.BadParameter:
        raise
    except Exception as exc:
        _console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code = ExitCode.ERROR) from None


def _parse_chain_steps(raw: str) -> list[EncodingFormat]:
    formats: list[EncodingFormat] = []
    valid_names = ", ".join(f.value for f in EncodingFormat)

    for step in raw.split(","):
        cleaned = step.strip().lower()
        try:
            formats.append(EncodingFormat(cleaned))
        except ValueError:
            raise typer.BadParameter(
                f"Unknown format '{cleaned}'. "
                f"Valid formats: {valid_names}"
            ) from None

    if not formats:
        raise typer.BadParameter("At least one step is required.")

    return formats
