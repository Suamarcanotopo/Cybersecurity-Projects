# Metadata Scrubber Tool

## What This Is

A command-line tool that strips privacy-sensitive metadata from files. Point it at your vacation photos and it removes GPS coordinates, camera serial numbers, and timestamps. Works on images (JPEG, PNG), PDFs, and Office documents (Word, Excel, PowerPoint).

## Why This Matters

Every file you create carries hidden data. That photo you posted online? It might reveal your home address through embedded GPS coordinates. The PDF you shared? Could leak your company name, author identity, and when you actually finished that "quick" report at 3 AM.

In 2012, a hacker group called Anonymous accidentally doxxed themselves when they posted a press release PDF that contained author metadata linking back to their real identities. In 2013, John McAfee was located in Guatemala after a Vice journalist posted a photo with EXIF GPS data intact. These aren't hypothetical risks.

**Real world scenarios where this applies:**
- Whistleblowers sharing documents without revealing their identity or location
- Journalists protecting sources by scrubbing metadata from leaked files before publication  
- Privacy-conscious individuals removing tracking data before sharing photos on social media
- Security researchers sanitizing proof-of-concept files before public disclosure
- Companies removing internal authorship and revision history before external distribution

## What You'll Learn

This project teaches you how metadata extraction and sanitization works under the hood. By building it yourself, you'll understand:

**Security Concepts:**
- Metadata leakage: Files contain hidden information beyond their visible content. Images store camera models, GPS coordinates, and edit history. Office docs track author names, company identifiers, and revision chains. This data persists even when you "delete" it from the UI.
- Privacy through data minimization: The best defense against metadata leaks is removing it entirely. You can't leak what isn't there. This tool shows how to surgically remove sensitive fields while preserving what's needed for the file to function.
- Defense in depth for privacy: Single-layer protection fails. This tool removes EXIF from images, textual chunks from PNGs, document properties from Office files, and info dictionaries from PDFs. Each format has its own metadata storage mechanism.

**Technical Skills:**
- Binary file format manipulation: Learn how JPEG stores EXIF in APP1 markers, how PNG uses tEXt chunks, and how PDF embeds info dictionaries. You'll parse these structures and rewrite files with metadata stripped.
- Factory pattern for extensibility: The `MetadataFactory` class (src/services/metadata_factory.py:28-66) routes files to appropriate handlers based on extension. Adding support for new formats means implementing the `MetadataHandler` interface without touching existing code.
- Concurrent batch processing: `BatchProcessor` (src/services/batch_processor.py) uses `ThreadPoolExecutor` to process thousands of files efficiently. You'll see how thread-safe path reservation and result aggregation work.

**Tools and Techniques:**
- Typer for building CLIs: The main.py file shows how to create a professional command line interface with argument validation, help text, and subcommands. No manual argparse boilerplate.
- Rich for terminal UI: Progress bars, tables, and colored output make the tool feel polished. Check src/utils/display.py to see how metadata gets formatted into readable tables.
- PIL/Pillow for image processing: Not just for resizing photos. You'll use it to read EXIF structures, manipulate PngInfo chunks, and save images without metadata (src/services/image_handler.py).

## Prerequisites

Before starting, you should understand:

**Required knowledge:**
- Python basics: Classes, inheritance, dictionaries, exception handling. You need to read `class ImageHandler(MetadataHandler)` and understand what's happening.
- Command line comfort: Running scripts, passing arguments, understanding file paths. This is a CLI tool, not a GUI.
- File I/O concepts: Reading bytes, writing output, copying files. The code manipulates files directly, not abstractions.

**Tools you'll need:**
- Python 3.10 or higher: The project uses modern type hints and pattern matching
- pip or uv: For installing dependencies from pyproject.toml
- A terminal: Windows Terminal, iTerm2, or any modern shell

**Helpful but not required:**
- EXIF specification knowledge: Makes it easier to understand why certain tags are preserved
- Understanding of Office Open XML: Helps when working with .docx/.xlsx/.pptx handlers
- Concurrency basics: ThreadPoolExecutor isn't magic, but you can learn it here

## Quick Start

Get the project running locally:
```bash
# Navigate to the project
cd PROJECTS/beginner/metadata-scrubber-tool

# Install dependencies (using uv - faster than pip)
uv pip install -e .

# Or with regular pip
pip install -e .

# Read metadata from a file
mst read tests/assets/test_images/test_fuji.jpg

# Scrub metadata from a single file
mst scrub tests/assets/test_images/test_fuji.jpg --output ./cleaned

# Process an entire directory
mst scrub ./photos -r -ext jpg --output ./scrubbed

# Verify metadata was removed
mst verify tests/assets/test_images/test_fuji.jpg ./cleaned/processed_test_fuji.jpg
```

Expected output: The `read` command shows a formatted table of metadata fields. The `scrub` command displays a progress bar and summary. The `verify` command compares before/after states with colored indicators.

## Project Structure
```
metadata-scrubber-tool/
├── src/
│   ├── commands/          # CLI command implementations
│   │   ├── read.py        # Display metadata from files
│   │   ├── scrub.py       # Remove metadata from files
│   │   └── verify.py      # Compare before/after metadata
│   ├── core/              # Format-specific metadata processors
│   │   ├── jpeg_metadata.py  # EXIF handling for JPEG
│   │   └── png_metadata.py   # Textual chunk + EXIF for PNG
│   ├── services/          # Business logic and handlers
│   │   ├── metadata_handler.py     # Abstract base class
│   │   ├── image_handler.py        # Images (delegates to core)
│   │   ├── pdf_handler.py          # PDF metadata
│   │   ├── excel_handler.py        # Excel workbooks
│   │   ├── powerpoint_handler.py   # PowerPoint presentations
│   │   ├── worddoc_handler.py      # Word documents
│   │   ├── metadata_factory.py     # Routes files to handlers
│   │   ├── batch_processor.py      # Concurrent processing
│   │   └── report_generator.py     # Verification reports
│   ├── utils/             # Helpers and utilities
│   └── main.py           # CLI entry point with Typer
└── tests/                # Unit, integration, and E2E tests
```

## Next Steps

1. **Understand the concepts** - Read [01-CONCEPTS.md](./01-CONCEPTS.md) to learn about metadata leakage, EXIF structure, and privacy risks
2. **Study the architecture** - Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) to see the factory pattern, handler hierarchy, and data flow
3. **Walk through the code** - Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for line-by-line explanations of how scrubbing works
4. **Extend the project** - Read [04-CHALLENGES.md](./04-CHALLENGES.md) for ideas like adding video support or cloud storage integration

## Common Issues

**ModuleNotFoundError when running `mst`**
```
ModuleNotFoundError: No module named 'src'
```
Solution: Install in editable mode with `pip install -e .` from the project root. The `-e` flag links the package so Python can find the `src` module.

**Permission denied when processing files**
Solution: Make sure you have write permissions to the output directory. The tool tries to create `./scrubbed` by default. Use `--output ~/Desktop/cleaned` to specify a location you control.

**"No metadata found" errors on PNG files**
Some PNGs genuinely have no metadata. This isn't a bug. Try running on `test_fuji.jpg` first to see the tool working, then experiment with other files.

## Related Projects

If you found this interesting, check out:
- **exiftool** - Industry standard CLI tool for reading/writing metadata. Written in Perl, handles 100+ formats. Study its source to see production-grade metadata handling.
- **mat2** - Metadata Anonymisation Toolkit used by Tails OS. Similar goals but written in Python with GUI support.
- **Image Scrubber** - Browser-based metadata remover. Good for understanding client-side file manipulation with JavaScript.
