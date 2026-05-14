# Extension Challenges

You've built the base project. Now make it yours by extending it with new features.

These challenges are ordered by difficulty. Start with easier ones to build confidence, then tackle harder ones when you want to dive deeper.

## Easy Challenges

### Challenge 1: Add Support for GIF Files

**What to build:**
Extend the tool to handle GIF metadata (comments, creation software, etc.)

**Why it's useful:**
GIFs often contain comment fields with author names or software info. Same privacy risks as other formats.

**What you'll learn:**
- Working with PIL for different image formats
- Extending the factory pattern
- Testing new file types

**Hints:**
- Look at `PngProcessor` for inspiration - GIFs have similar text-based metadata
- Update `MetadataFactory.get_handler()` to route .gif files
- Test with animated GIFs to ensure frame data isn't corrupted

**Test it works:**
```bash
# Create test GIF with metadata
mst read test.gif  # Should show metadata
mst scrub test.gif --output ./clean
mst verify test.gif ./clean/processed_test.gif
```

### Challenge 2: Add Dry-Run Mode for Read Command

**What to build:**
Add `--dry-run` flag to read command that simulates what would be read without actually doing it

**Why it's useful:**
Users want to preview operations without side effects. Good pattern for CLI tools.

**What you'll learn:**
- Typer option handling
- Command design patterns

**Hints:**
- Check how `scrub.py` implements dry-run
- Just print what files would be processed, don't actually read them
- Update help text to explain dry-run behavior

### Challenge 3: Add JSON Output Format

**What to build:**
Add `--format json` option to read command that outputs metadata as JSON instead of tables

**Why it's useful:**
JSON output enables piping to other tools like jq or scripting workflows

**What you'll learn:**
- Multiple output format handling
- JSON serialization of complex types

**Hints:**
- Add a new display function in `src/utils/display.py`
- Handle bytes and other non-JSON-serializable types
- Test with: `mst read photo.jpg --format json | jq .`

## Intermediate Challenges

### Challenge 4: Add Video File Support

**What to build:**
Support for video formats (.mp4, .mov, .avi) using ffprobe/ffmpeg

**Why it's useful:**
Videos contain extensive metadata: GPS from phones, camera models, edit software, etc.

**What you'll learn:**
- Working with external command-line tools
- Subprocess handling in Python
- Video metadata structure

**Implementation approach:**

1. **Create VideoHandler** in `src/services/video_handler.py`
   - Use subprocess to call `ffprobe -show_format -show_streams video.mp4`
   - Parse JSON output for metadata
   - Use `ffmpeg` with `-map_metadata -1` to strip metadata

2. **Update Factory**
   - Add video extensions to `MetadataFactory`

3. **Test edge cases:**
   - Multi-stream videos (audio + video)
   - Codec-specific metadata
   - Large files (100MB+)

**Extra credit:**
Preserve subtitle tracks while removing metadata

### Challenge 5: Add Recursive Directory Stats

**What to build:**
Add `--stats` flag that shows metadata statistics across all files in a directory

**Why it's useful:**
Helps users understand what metadata exists before scrubbing

**Implementation:**
```python
# Example output
Found 150 JPEG files:
  - 142 contain GPS data
  - 87 contain camera serial numbers
  - 150 contain timestamps
  - 23 contain author names
```

**Hints:**
- Create new command `mst stats ./photos -r -ext jpg`
- Aggregate metadata across all files
- Use Counter from collections to track field frequency

## Advanced Challenges

### Challenge 6: Implement Metadata Profiles

**What to build:**
Configurable metadata removal profiles (minimal, standard, aggressive)

**Why this is hard:**
Requires designing a flexible configuration system and understanding which metadata is safe to remove for different use cases

**What you'll learn:**
- Configuration management
- Security vs usability tradeoffs
- Domain-specific requirements

**Architecture changes:**
```
┌─────────────────┐
│  Profile YAML   │  (user-defined rules)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Profile Loader  │  (parse and validate)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│    Handler      │  (apply rules during wipe)
└─────────────────┘
```

**Example profile (profiles/minimal.yaml):**
```yaml
name: minimal
description: Remove only GPS and author data
preserve:
  - created
  - modified
  - camera_model
remove:
  - gps_*
  - author
  - copyright
```

**Implementation steps:**

1. Create profile parser in `src/services/profile_loader.py`
2. Modify handlers to accept profile parameter
3. Update wipe() methods to consult profile rules
4. Add `--profile minimal` CLI flag

**Gotchas:**
- YAML parsing can introduce security issues (use safe_load)
- Profile validation is critical (bad profiles could corrupt files)
- Cache parsed profiles for performance

### Challenge 7: Add Cloud Storage Support

**What to build:**
Process files directly from S3/Google Cloud Storage without downloading locally

**Architecture:**
```
Cloud Storage API
      ↓
Streaming Download
      ↓
Process in Memory
      ↓
Streaming Upload
```

**Why this is hard:**
Memory management, authentication, network errors, partial failures

**Implementation approach:**

1. **Abstract filesystem layer**
```python
   class StorageBackend(ABC):
       @abstractmethod
       def read(self, path: str) -> bytes:
           pass
       
       @abstractmethod
       def write(self, path: str, data: bytes) -> None:
           pass
```

2. **Implement S3 backend**
```python
   class S3Backend(StorageBackend):
       def __init__(self, bucket: str):
           self.s3 = boto3.client('s3')
           self.bucket = bucket
```

3. **Update handlers to use abstraction**
   - Replace Path() with backend.read()
   - Replace file writes with backend.write()

**Resources:**
- boto3 documentation for S3
- google-cloud-storage for GCS

## Performance Challenges

### Challenge 8: Implement Streaming Processing for Large Files

**The goal:**
Process files >1GB without loading entirely into memory

**Current bottleneck:**
`Image.open()` loads entire file. `shutil.copy2()` reads whole file.

**Optimization approach:**
```python
def stream_process_jpeg(input_path, output_path):
    # Read in chunks
    with open(input_path, 'rb') as f_in:
        with open(output_path, 'wb') as f_out:
            # Copy until EXIF marker
            while True:
                chunk = f_in.read(8192)
                if b'\xff\xe1' in chunk:  # APP1 marker
                    # Process EXIF, skip it
                    break
                f_out.write(chunk)
            
            # Copy rest without EXIF
            shutil.copyfileobj(f_in, f_out)
```

**Test with:**
Create 1GB test file, monitor memory usage with:
```bash
/usr/bin/time -v mst scrub huge_file.jpg
```

### Challenge 9: Add Caching for Repeated Operations

**The goal:**
Cache metadata reads to avoid re-parsing same files

**Implementation:**
```python
from functools import lru_cache
import hashlib

def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

@lru_cache(maxsize=128)
def cached_metadata_read(file_hash: str, filepath: str):
    handler = MetadataFactory.get_handler(filepath)
    return handler.read()
```

**Benchmarks:**
Test with 1000 files processed twice. Second run should be 10x faster.

## Security Challenges

### Challenge 10: Add Steganography Detection

**What to implement:**
Detect hidden data in image pixel values or LSB encoding

**Threat model:**
Metadata scrubbing doesn't help if data is hidden in pixels

**Implementation:**
```python
def detect_lsb_steganography(image_path: Path) -> bool:
    img = Image.open(image_path)
    pixels = np.array(img)
    
    # Analyze LSB distribution
    lsb = pixels & 1
    # Random data has ~50% 1s, encoded data shows patterns
    if not (0.48 < np.mean(lsb) < 0.52):
        return True  # Suspicious
    return False
```

This is beyond metadata but teaches important privacy concepts.

### Challenge 11: Implement Secure Deletion

**The goal:**
Overwrite original files after scrubbing to prevent forensic recovery

**Why this matters:**
Deleting files doesn't erase data from disk. Metadata could be recovered.

**Implementation:**
```python
def secure_delete(filepath: Path):
    # Overwrite with random data
    size = filepath.stat().st_size
    with open(filepath, 'wb') as f:
        f.write(os.urandom(size))
    
    # Overwrite with zeros
    with open(filepath, 'wb') as f:
        f.write(b'\x00' * size)
    
    # Finally delete
    filepath.unlink()
```

**Warning:** Only works on HDDs, not SSDs with wear leveling.

## Real World Integration

### Integrate with ExifTool

**The goal:**
Use ExifTool for formats this project doesn't support

**Implementation:**
```python
def exiftool_fallback(filepath: Path) -> dict:
    result = subprocess.run(
        ['exiftool', '-json', str(filepath)],
        capture_output=True,
        text=True
    )
    return json.loads(result.stdout)[0]
```

Add as fallback in factory when no handler exists.

## Mix and Match

Combine challenges for bigger projects:

**Project: Privacy-Focused Photo Sharing Tool**
- Challenge 4 (video) + Challenge 7 (cloud) + Challenge 11 (secure delete)
- Result: Upload photos/videos to S3 with metadata stripped and originals securely deleted

**Project: Corporate Document Scrubber**
- Challenge 6 (profiles) + Challenge 2 (dry-run) + Challenge 5 (stats)
- Result: Enterprise tool with compliance profiles and audit trails

## Getting Help

Stuck on a challenge?

1. **Read the existing code** - Similar feature probably exists
2. **Check tests** - Test files show how features are used
3. **Search issues** - Someone may have asked already
4. **Start small** - Implement minimal version first

## Challenge Completion

Track your progress:

- [ ] Easy Challenge 1: GIF support
- [ ] Easy Challenge 2: Dry-run for read
- [ ] Easy Challenge 3: JSON output
- [ ] Intermediate Challenge 4: Video support
- [ ] Intermediate Challenge 5: Directory stats
- [ ] Advanced Challenge 6: Metadata profiles
- [ ] Advanced Challenge 7: Cloud storage
- [ ] Performance Challenge 8: Streaming
- [ ] Performance Challenge 9: Caching
- [ ] Security Challenge 10: Steganography detection
- [ ] Security Challenge 11: Secure deletion

Completed all? You've mastered this project. Time to build something new or contribute back.
