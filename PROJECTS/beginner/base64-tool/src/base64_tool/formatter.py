"""
©AngelaMos | 2026
formatter.py

Rich terminal output for all CLI commands

Handles all display logic for encoded strings, decoded bytes,
detection tables, peel layer summaries, and chain step results.
Detects whether stdout is a TTY or a pipe and switches between
Rich-formatted panels and raw text output. All Rich output goes
to stderr so piped stdout stays machine-readable.

Key exports:
  print_encoded() - Displays an encoded string in a Rich panel or raw to stdout
  print_decoded() - Displays decoded bytes as text or hex fallback
  print_detection() - Renders a confidence table for detect results
  print_peel_result() - Renders each peel layer and a final output panel
  print_chain_result() - Renders each encoding step and the final chain result
  print_score_breakdown() - Renders per-format score table for verbose mode
  is_piped() - Returns True when stdout is not a TTY

Connects to:
  constants.py - imports CONFIDENCE_THRESHOLD, PREVIEW_LENGTH, EncodingFormat
  detector.py - imports DetectionResult
  peeler.py - imports PeelResult
  utils.py - imports safe_bytes_preview
  cli.py - imports all print_* functions
"""

import sys

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text

from base64_tool.constants import (
    CONFIDENCE_THRESHOLD,
    EncodingFormat,
    PREVIEW_LENGTH,
)
from base64_tool.detector import DetectionResult
from base64_tool.peeler import PeelResult
from base64_tool.utils import safe_bytes_preview


console = Console(stderr = True)


def is_piped() -> bool:
    return not sys.stdout.isatty()


def write_raw(text: str) -> None:
    sys.stdout.write(text)
    sys.stdout.flush()


def print_encoded(result: str, fmt: EncodingFormat) -> None:
    if is_piped():
        write_raw(result)
        return
    panel = Panel(
        Text(result,
             style = "green"),
        title = f"[bold cyan]{fmt.value}[/bold cyan] encoded",
        border_style = "cyan",
    )
    console.print(panel)


def print_decoded(result: bytes) -> None:
    preview = safe_bytes_preview(result, length = 4096)
    if is_piped():
        write_raw(preview)
        return
    panel = Panel(
        Text(preview,
             style = "green"),
        title = "[bold cyan]Decoded[/bold cyan]",
        border_style = "cyan",
    )
    console.print(panel)


def print_score_breakdown(
    scores: dict[EncodingFormat,
                 float],
) -> None:
    table = Table(
        title = "Score Breakdown",
        show_header = True,
        header_style = "bold magenta",
    )
    table.add_column("Format", style = "cyan", min_width = 10)
    table.add_column(
        "Score",
        justify = "right",
        min_width = 8,
    )
    table.add_column("Status", min_width = 10)

    sorted_scores = sorted(
        scores.items(),
        key = lambda x: x[1],
        reverse = True,
    )
    for fmt, score in sorted_scores:
        color = _confidence_color(score)
        if score >= CONFIDENCE_THRESHOLD:
            status = "[green]detected[/green]"
        elif score > 0:
            status = "[yellow]below threshold[/yellow]"
        else:
            status = "[dim]no match[/dim]"
        table.add_row(
            fmt.value,
            f"[{color}]{score:.0%}[/{color}]",
            status,
        )

    console.print(table)


def print_detection(
    results: list[DetectionResult],
    *,
    verbose_scores: dict[EncodingFormat,
                         float] | None = None,
) -> None:
    if verbose_scores is not None:
        print_score_breakdown(verbose_scores)
        console.print()

    if not results:
        console.print("[yellow]No encoding format detected.[/yellow]")
        return

    table = Table(
        title = "Detection Results",
        show_header = True,
        header_style = "bold magenta",
    )
    table.add_column("Format", style = "cyan", min_width = 10)
    table.add_column(
        "Confidence",
        justify = "right",
        style = "green",
        min_width = 12,
    )
    table.add_column("Decoded Preview", style = "dim")

    for result in results:
        confidence_str = f"{result.confidence:.0%}"
        preview = ""
        if result.decoded is not None:
            preview = safe_bytes_preview(
                result.decoded,
                PREVIEW_LENGTH,
            )
        table.add_row(
            result.format.value,
            confidence_str,
            preview,
        )

    console.print(table)


def print_peel_result(
    result: PeelResult,
    *,
    verbose: bool = False,
) -> None:
    if not result.success:
        console.print("[yellow]No encoding layers detected.[/yellow]")
        return

    layer_count = len(result.layers)
    suffix = "s" if layer_count > 1 else ""
    console.print()
    console.print(
        f"[bold cyan]Peeled {layer_count} encoding "
        f"layer{suffix}[/bold cyan]"
    )
    console.print()

    for layer in result.layers:
        color = _confidence_color(layer.confidence)
        console.print(
            f"  [bold]Layer {layer.depth}[/bold]  "
            f"[cyan]{layer.format.value}[/cyan]  "
            f"[{color}]{layer.confidence:.0%}[/{color}]"
        )
        console.print(f"    [dim]{layer.decoded_preview}[/dim]")

        if verbose and layer.all_scores:
            console.print()
            print_score_breakdown(dict(layer.all_scores))
            console.print()

    console.print()

    preview = safe_bytes_preview(result.final_output, length = 4096)
    panel = Panel(
        Text(preview,
             style = "bold green"),
        title = "[bold]Final Output[/bold]",
        border_style = "green",
        subtitle = (f"[dim]{layer_count} layer{suffix} peeled[/dim]"),
    )
    console.print(panel)


def print_chain_result(
    steps: list[tuple[EncodingFormat,
                      str]],
    final: str,
) -> None:
    if is_piped():
        write_raw(final)
        return

    console.print()
    console.print("[bold cyan]Encoding Chain[/bold cyan]")
    console.print()

    for i, (fmt, intermediate) in enumerate(steps):
        marker = "start" if i == 0 else "step"
        arrow = f"  [{marker}] " if i == 0 else "    -> "
        truncated = intermediate[: PREVIEW_LENGTH]
        ellipsis = "..." if len(intermediate) > PREVIEW_LENGTH else ""
        console.print(
            f"{arrow}[cyan]{fmt.value}[/cyan]  "
            f"[dim]{truncated}{ellipsis}[/dim]"
        )

    console.print()
    panel = Panel(
        Text(final,
             style = "green"),
        title = "[bold]Chain Result[/bold]",
        border_style = "cyan",
        subtitle = f"[dim]{len(steps)} steps[/dim]",
    )
    console.print(panel)


def _confidence_color(confidence: float) -> str:
    if confidence >= 0.9:
        return "green"
    if confidence >= 0.7:
        return "yellow"
    return "red"
