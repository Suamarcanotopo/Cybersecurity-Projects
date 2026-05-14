# Implementation Guide

This document walks through the actual code. We'll build key features step by step and explain the decisions along the way.

## File Structure Walkthrough
```
src/
├── commands/
│   ├── read.py          # Display metadata without modification
│   ├── scrub.py         # Remove metadata from files
│   └── verify.py        # Compare before/after states
├── core/
│   ├── jpeg_metadata.py # EXIF parsing for JPEG
│   └── png_metadata.py  # Metadata handling for PNG
├── services/
│   ├── metadata_handler.py     # Abstract base class
│   ├── image_handler.py        # Images (JPEG/PNG)
│   ├── pdf_handler.py          # PDF documents
│   ├── excel_handler.py        # Excel workbooks
│   ├── metadata_factory.py     # Route files to handlers
│   └── batch_processor.py      # Concurrent processing
└── utils/
    ├── display.py       # Rich terminal formatting
    └── exceptions.py    # Custom error types
```

## Building the Factory Pattern

### The Problem

When a user runs `mst scrub photo.jpg`, we need to determine which handler to use. Different file types need different handlers. We could scatter `if ext == ".jpg"` checks everywhere, but that's unmaintainable.

### The Solution

Centralize routing in `MetadataFactory` (src/services/metadata_factory.py):
```python
class MetadataFactory:
    @staticmethod
    def get_handler(filepath: str):
        ext = Path(filepath).suffix.lower()
        if Path(filepath).is_file():
            if ext in [".jpg", ".jpeg", ".png"]:
                return ImageHandler(filepath)
            elif ext == ".pdf":
                return PDFHandler(filepath)
            elif ext in [".xlsx", ".xlsm"]:
                return ExcelHandler(filepath)
            else:
                raise UnsupportedFormatError(
                    f"No handler for {ext} files"
                )
        else:
            raise ValueError(f"{filepath} is not a file")
```

**Why this code works:**
- Line 4: Extract extension and normalize to lowercase (.JPG → .jpg)
- Line 5: Verify it's actually a file (prevents directory processing)
- Lines 6-12: Route based on extension to appropriate handler class
- Line 14: Explicit error for unsupported formats (better than silent failure)

**Common mistake here:**
```python
# Wrong - trusts extension blindly
if filepath.endswith(".jpg"):
    return ImageHandler(filepath)

# Better - verifies file exists first
if Path(filepath).is_file() and ext == ".jpg":
    return ImageHandler(filepath)
```

The wrong approach fails when users pass non-existent paths or when file extensions lie about content.

## Building JPEG Metadata Extraction

### Step 1: Reading EXIF Data

From `JpegProcessor.get_metadata()` (src/core/jpeg_metadata.py:32-64):
```python
def get_metadata(self, img: Image.Image) -> JpegMetadataResult:
    if "exif" not in img.info:
        raise MetadataNotFoundError("No EXIF data found")

    exif_dict = piexif.load(img.info["exif"])
    for ifd, value in exif_dict.items():
        if not isinstance(exif_dict[ifd], dict):
            continue  # Skip thumbnail blob

        for tag, tag_value in exif_dict[ifd].items():
            tag_name = str(piexif.TAGS[ifd][tag]["name"])
            
            # Preserve structural tags
            if tag_name in ("Orientation", "ColorSpace", "ExifTag"):
                continue
                
            self.tags_to_delete.append(tag)
            self.data[tag_name] = tag_value

    return {"data": self.data, "tags_to_delete": self.tags_to_delete}
```

**What's happening:**
1. Line 2-3: Check if EXIF exists before trying to parse it
2. Line 5: piexif.load() parses binary EXIF into nested dicts
3. Line 6-8: Iterate IFDs (Image File Directories) - containers for tags
4. Line 10-11: Get human-readable tag name from numeric ID
5. Line 13-14: Skip tags needed for proper image display
6. Line 16-17: Mark tag for deletion and store its value

**Why we do it this way:**
Removing Orientation breaks image rotation. Removing ColorSpace breaks color rendering. We preserve what's needed for display, delete everything else.

**Alternative approach:**
```python
# Simpler but wrong - removes everything
for tag in exif_dict["0th"]:
    del exif_dict["0th"][tag]
```

This corrupts images. The photo displays upside-down or with wrong colors.

### Step 2: Removing Metadata

From `JpegProcessor.delete_metadata()` (src/core/jpeg_metadata.py:66-96):
```python
def delete_metadata(self, img: Image.Image, tags_to_delete: list[int]):
    try:
        exif_dict = piexif.load(img.info["exif"])
        for ifd, value in exif_dict.items():
            if not isinstance(exif_dict[ifd], dict):
                continue

            for tag in list(exif_dict[ifd]):
                if tag in tags_to_delete:
                    del exif_dict[ifd][tag]

        return exif_dict
    except Exception as e:
        raise MetadataProcessingError(f"Error: {str(e)}")
```

**Key parts explained:**
- Line 8: `list(exif_dict[ifd])` creates a copy of keys before iteration (prevents "dict changed size during iteration" error)
- Line 9-10: Only delete tags we marked during read phase
- Line 12: Return modified dict for piexif.dump() to serialize

### Step 3: Saving the Cleaned File

From `ImageHandler.save()` (src/services/image_handler.py:117-147):
```python
def save(self, output_path: str | None = None) -> None:
    if not output_path:
        raise ValueError("output_path is required")

    actual_format = self.detected_format or self._detect_format()

    if actual_format == "jpeg":
        shutil.copy2(self.filepath, output_path)
        with Image.open(output_path) as img:
            exif_bytes = piexif.dump(self.processed_metadata)
            img.save(output_path, exif=exif_bytes)
    elif actual_format == "png":
        with Image.open(self.filepath) as img:
            img.save(output_path, format="PNG", exif=None, pnginfo=None)
```

**What's happening:**
1. Lines 2-3: Validate output path exists
2. Line 5: Use cached format or detect it
3. Lines 7-11: JPEG - copy file then rewrite with cleaned EXIF
4. Lines 12-14: PNG - save fresh copy without any metadata

**Why JPEG copies then modifies:**
We preserve JPEG compression. If we re-encode, quality degrades. Copy preserves original compression, we just swap EXIF.

## Concurrent Batch Processing

### The Challenge

Processing 1000 files sequentially takes minutes. We need concurrency.

### Implementation

From `BatchProcessor.process_batch()` (src/services/batch_processor.py:134-168):
```python
def process_batch(
    self,
    files: Iterable[Path],
    progress_callback: Callable[[FileResult], None] | None = None,
) -> list[FileResult]:
    file_list = list(files)

    with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
        future_to_file = {
            executor.submit(self.process_file, file): file
            for file in file_list
        }

        for future in as_completed(future_to_file):
            result = future.result()
            if progress_callback:
                progress_callback(result)

    return self.results
```

**What's happening:**
1. Line 8: Create thread pool with configurable worker count
2. Lines 9-12: Submit all files to executor, get Future objects
3. Lines 14-17: Process results as workers complete (not in submission order)
4. Line 16: Callback updates progress bar in real-time

**Thread safety:**
The `_get_unique_output_path()` method uses locks to prevent race conditions:
```python
def _get_unique_output_path(self, file: Path, reserve: bool = True) -> Path:
    with self._path_lock:  # Thread-safe
        output_path = self.output_dir / f"processed_{file.name}"
        
        counter = 1
        while output_path.exists():
            output_path = self.output_dir / f"processed_{file.name}_{counter}{file.suffix}"
            counter += 1
        
        if reserve:
            output_path.touch()  # Reserve path
        
        return output_path
```

Without the lock, two threads processing "photo.jpg" simultaneously could both see the path as available and overwrite each other.

## Error Handling Patterns

### Graceful Degradation

When one file fails, don't stop the batch:
```python
# From BatchProcessor.process_file() (batch_processor.py:98-132)
try:
    handler = MetadataFactory.get_handler(str(file))
    handler.read()
    handler.wipe()
    output_path = self._get_unique_output_path(file)
    handler.save(str(output_path))
    
    result = FileResult(
        filepath=file,
        success=True,
        action="scrubbed",
        output_path=output_path,
    )
except Exception as e:
    result = FileResult(
        filepath=file,
        success=False,
        action="skipped",
        error=str(e),
    )
    
self._append_result(result)
return result
```

**Why this specific handling:**
Each file gets its own try/except. One corrupted file doesn't stop processing 999 others. The result object tracks success/failure for later reporting.

### Custom Exceptions

From src/utils/exceptions.py:
```python
class MetadataException(Exception):
    """Base class for all metadata-related exceptions."""

class UnsupportedFormatError(MetadataException):
    """Raised when attempting to process unsupported file format."""

class MetadataNotFoundError(MetadataException):
    """Raised when no metadata is found in a file."""
```

**Why custom exceptions:**
Callers can catch specific errors: `except MetadataNotFoundError` vs generic `except Exception`. Better than checking error message strings.

## Testing Strategy

### Unit Test Example

From tests/unit/test_image_handler.py:
```python
def test_read_image_metadata(jpg_test_file):
    processor = ImageHandler(jpg_test_file)
    metadata = processor.read()
    
    assert processor.metadata == metadata
    assert processor.tags_to_delete is not None
    assert isinstance(metadata, dict)
```

**What this tests:**
- Read returns a dictionary
- Internal state (tags_to_delete) is populated
- Metadata field matches return value

### Integration Test Example

From tests/integration/test_metadata_factory.py:
```python
def test_save_processed_image_metadata(jpg_test_file):
    output_dir = Path("./tests/assets/output")
    output_dir.mkdir(parents=True, exist_ok=True)

    handler = MetadataFactory.get_handler(str(jpg_test_file))
    handler.read()
    handler.wipe()
    
    output_file = output_dir / Path(jpg_test_file).name
    handler.save(str(output_file))
    
    assert output_file.exists()
```

**Why these specific assertions:**
We test the full pipeline through the factory. If the output file exists and is valid, the entire read→wipe→save flow worked.

## Common Implementation Pitfalls

### Pitfall 1: Forgetting to Validate Output Path

**Symptom:**
`TypeError: expected str, bytes or os.PathLike object, not NoneType`

**Cause:**
```python
# Bad - no validation
def save(self, output_path):
    shutil.copy2(self.filepath, output_path)  # Crashes if None
```

**Fix:**
```python
# Good - explicit validation
def save(self, output_path: str | None = None) -> None:
    if not output_path:
        raise ValueError("output_path is required")
    # Now safe to use
```

**Why this matters:**
Clear error messages help debugging. "output_path is required" is better than a cryptic TypeError.

### Pitfall 2: Modifying Dict During Iteration

**Symptom:**
`RuntimeError: dictionary changed size during iteration`

**Cause:**
```python
# Bad
for tag in exif_dict[ifd]:
    del exif_dict[ifd][tag]  # Modifies dict while iterating
```

**Fix:**
```python
# Good
for tag in list(exif_dict[ifd]):  # Iterate over copy
    del exif_dict[ifd][tag]
```

### Pitfall 3: Not Handling Format Detection Failures

**Symptom:**
Renamed PNG as .jpg processes incorrectly

**Fix:**
```python
# From ImageHandler._detect_format()
with Image.open(Path(self.filepath)) as img:
    if img.format is None:
        raise UnsupportedFormatError("Could not detect format")
    
    pillow_format = img.format.lower()
    normalized = FORMAT_MAP.get(pillow_format)
    
    if normalized is None:
        raise UnsupportedFormatError(f"Unsupported: {pillow_format}")
```

Use Pillow's actual format detection, not file extension.

## Code Organization Principles

### Why Commands Are Separate from Services
```python
# commands/scrub.py - UI concerns
console.print("🔎 Processing...")
progress = Progress(...)

# services/batch_processor.py - Business logic
def process_file(self, file: Path) -> FileResult:
    # No UI code here
```

**Benefit:**
You can use BatchProcessor in a web API without Rich/Typer dependencies. Commands stay thin, services stay reusable.

### Naming Conventions

- `*Handler` classes inherit from MetadataHandler
- `*Processor` classes handle low-level format parsing
- `*Result` dataclasses represent operation outcomes
- `get_*` functions retrieve data without side effects
- `process_*` functions modify state or files

## Dependencies

### Why Each Dependency

- **typer** (0.21.0): CLI framework with automatic help generation and type validation
- **rich** (14.0.0): Terminal formatting for progress bars and tables
- **pillow** (12.0.0): Image loading and EXIF access
- **piexif** (1.1.3): EXIF manipulation (Pillow is read-only for EXIF)
- **pypdf** (6.5.0): PDF metadata reading/writing
- **openpyxl** (3.1.5): Excel file handling
- **python-pptx** (1.0.2): PowerPoint metadata
- **python-docx** (1.2.0): Word document metadata

### Security Scanning

Check for vulnerabilities:
```bash
pip install safety
safety check --file pyproject.toml
```

If you see vulnerabilities in dependencies, update to patched versions or find alternatives.

## Build and Deploy

### Building
```bash
# Install in development mode
pip install -e .

# Run tests
pytest

# Type checking
mypy src/

# Linting
ruff check src/
```

### Local Development
```bash
# Start development with auto-reload
# (Not applicable for CLI - just run directly)
mst scrub test.jpg

# Verbose logging for debugging
mst scrub test.jpg --verbose
```

## Next Steps

You've seen how the code works. Now:

1. **Try the challenges** - [04-CHALLENGES.md](./04-CHALLENGES.md) has extension ideas
2. **Add a feature** - Try implementing video metadata support
3. **Read related projects** - Study ExifTool source to see production patterns
