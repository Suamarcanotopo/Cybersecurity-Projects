# Core Security Concepts

This document explains the security concepts you'll encounter while building this project. These are not just definitions. We'll dig into why they matter and how they actually work.

## Metadata Leakage

### What It Is

Metadata is data about data. When you take a photo, the image pixels are the data. The camera model, GPS coordinates, timestamp, and camera settings are metadata. This information gets embedded in the file itself, invisible to casual viewing but trivially extractable with the right tools.

File formats define specific structures for storing this metadata. JPEG uses EXIF (Exchangeable Image File Format) tags in APP1 application markers. PNG stores text chunks with key-value pairs. PDF embeds an info dictionary. Office formats use core properties in XML structures.

### Why It Matters

Metadata leaks reveal information you didn't intend to share. This isn't theoretical. Real incidents have exposed:

- **Location tracking**: GPS coordinates in photos reveal where you live, work, or travel. Stalkers and burglars love this.
- **Identity exposure**: Author names in documents link anonymous content back to real people. Whistleblowers have been identified this way.
- **Operational security failures**: Timestamps prove when you were somewhere. Camera serial numbers link multiple photos from the same device.
- **Company information leaks**: Document metadata exposes company names, software versions, and editing patterns.

### How It Works

Here's how JPEG metadata gets embedded. When your camera saves a photo, it creates a file structure like this:
```
┌─────────────────┐
│  JPEG Marker    │  0xFF 0xD8 (Start of Image)
├─────────────────┤
│  APP0 Marker    │  0xFF 0xE0 (JFIF data)
├─────────────────┤
│  APP1 Marker    │  0xFF 0xE1 (EXIF data starts here)
│   ┌───────────┐ │
│   │ TIFF Hdr  │ │  "II" or "MM" (byte order)
│   ├───────────┤ │
│   │ IFD 0     │ │  Image tags
│   ├───────────┤ │
│   │ EXIF IFD  │ │  Camera settings
│   ├───────────┤ │
│   │ GPS IFD   │ │  Location data
│   └───────────┘ │
├─────────────────┤
│  Image Data     │  Compressed JPEG data
├─────────────────┤
│  EOI Marker     │  0xFF 0xD9 (End of Image)
└─────────────────┘
```

When you open the image in a photo viewer, it reads the compressed data and displays pixels. The EXIF block sits there, ignored by display logic but fully accessible to anyone who looks.

In our code, `JpegProcessor.get_metadata()` (src/core/jpeg_metadata.py:32-64) extracts this:
```python
exif_dict = piexif.load(img.info["exif"])
for ifd, value in exif_dict.items():
    if not isinstance(exif_dict[ifd], dict):
        continue
    
    for tag, tag_value in exif_dict[ifd].items():
        tag_name = piexif.TAGS[ifd][tag]["name"]
        self.data[tag_name] = tag_value
```

The `piexif` library parses the binary EXIF structure and returns nested dictionaries organized by IFD (Image File Directory). Each IFD contains tags with numeric IDs that we translate to human-readable names.

### Common Attacks

Real attackers exploit metadata in these ways:

1. **Geolocation stalking**: Download photos from social media, extract GPS coordinates, track the person's movements over time. Tools like ExifTool make this trivial. A single photo with GPS data can reveal home addresses.

2. **Identity correlation**: Link anonymous accounts by matching camera serial numbers across photos. If someone posts from "anonymous_user_123" but the photos have the same camera serial as their real Facebook account, you've deanonymized them.

3. **Timing analysis**: Document timestamps reveal when files were created versus when they were claimed to be created. This has exposed fraud cases where "original" documents were actually created years later.

4. **Infrastructure reconnaissance**: Software version metadata in Office docs reveals what tools a company uses. Attackers use this to target known vulnerabilities in specific versions.

### Defense Strategies

Protect against metadata leaks by removing it before sharing files:

**Strip EXIF entirely from images**: Our `JpegProcessor.delete_metadata()` (src/core/jpeg_metadata.py:66-96) preserves only Orientation and ColorSpace tags because removing them breaks image display. Everything else goes.

**Remove textual chunks from PNGs**: The `PngProcessor` (src/core/png_metadata.py) handles both EXIF and PngInfo text chunks. Some PNGs don't have EXIF but still leak data through Author, Comment, and Software text keys.

**Clear document properties from Office files**: Excel, Word, and PowerPoint files store metadata in core properties. The handlers in src/services/ wipe author, company, and keywords but preserve timestamps needed for file validity.

**Use metadata anonymization tools consistently**: Manual removal is error-prone. Automate it. This tool processes entire directories recursively, ensuring you don't miss files.

## File Format Internals

### What It Is

File formats are binary structures with specific layouts. JPEG isn't "just an image". It's a sequence of markers and segments following ISO/IEC 10918 specification. PDF isn't "just a document". It's a tree structure of objects following ISO 32000.

Understanding format internals lets you manipulate files surgically instead of hoping libraries do the right thing.

### Why It Matters

If you don't understand the format, you'll either:
- Delete too much and corrupt the file
- Delete too little and leak metadata anyway
- Rely entirely on third-party libraries without understanding what they're doing

Our tool needs to preserve structural integrity while removing privacy-sensitive data. That requires knowing what's safe to remove.

### How It Works

Take PNG format. It's a sequence of chunks, each with:
```
Length (4 bytes) | Type (4 bytes) | Data (variable) | CRC (4 bytes)
```

Critical chunks like IHDR (image header) and IDAT (image data) must stay. Ancillary chunks like tEXt (textual data) can be stripped. Our code differentiates:
```python
# From src/core/png_metadata.py:67-86
if key in ("icc_profile", "exif", "transparency", "gamma"):
    continue  # Skip critical data

if isinstance(value, (str, bytes)):
    found_metadata = True
    self.data[f"PNG:{key}"] = value
    self.text_keys_to_delete.append(key)
```

### Common Pitfalls

Where developers get this wrong:

**Mistake 1: Removing critical tags**
```python
# Bad - nukes everything including structural data
for tag in exif_dict["0th"]:
    del exif_dict["0th"][tag]

# Good - preserves Orientation and ColorSpace
if tag_name == "Orientation" or tag_name == "ColorSpace":
    continue
self.tags_to_delete.append(tag)
```

Why this matters: Removing Orientation causes photos to display rotated 90 degrees. Removing ColorSpace breaks color rendering. The image "works" but looks wrong.

**Mistake 2: Trusting file extensions**
```python
# Bad - attacker renames PNG to .jpg
if filepath.endswith(".jpg"):
    use_jpeg_handler()

# Good - actual format detection
with Image.open(filepath) as img:
    if img.format.lower() == "png":
        use_png_handler()
```

Our `ImageHandler._detect_format()` (src/services/image_handler.py:43-60) uses Pillow's format detection, not the extension. File extensions lie. File signatures don't.

## Privacy Through Data Minimization

### What It Is

Data minimization means collecting and retaining only what's necessary. Don't store data you don't need. Don't share data you don't need to share.

For file metadata, this translates to: if the file works without a field, remove it.

### Why It Matters

You can't leak what you don't have. Encrypted metadata is better than plaintext metadata, but absent metadata is best. Each field you preserve is a potential privacy leak.

### Common Mistakes

**Leaving preserved properties configurable**
```python
# Bad - user might not know what to preserve
PRESERVED = config.get("preserved_fields", [])

# Good - hardcoded safe defaults  
PRESERVED_PROPERTIES = {"created", "modified", "language"}
```

Users aren't security experts. They'll preserve Author "just in case" and then leak their name. We make the safe choice for them.

## How These Concepts Relate

Metadata leakage happens because file formats embed extra data. Understanding format internals lets you remove that data safely. Data minimization provides the principle: remove everything you can.
```
Format Internals
    ↓
  enables
    ↓
Surgical Metadata Removal
    ↓
  implements
    ↓
Data Minimization
    ↓
  prevents
    ↓
Metadata Leakage
```

## Industry Standards and Frameworks

### OWASP Top 10

This project addresses:
- **A01:2021 - Broken Access Control**: Metadata leaks allow attackers to access information they shouldn't have. GPS coordinates in photos are access control failures. You didn't explicitly grant access to your location, but the metadata did.
- **A04:2021 - Insecure Design**: Systems that don't strip metadata before sharing files have insecure design. Social media platforms that preserve EXIF in uploaded photos are insecurely designed.

### MITRE ATT&CK

Relevant techniques:
- **T1083 - File and Directory Discovery**: Attackers extract metadata to discover information about target systems, software versions, and organizational structure.
- **T1589.002 - Gather Victim Identity Information: Email Addresses**: Document metadata often contains email addresses of authors and collaborators.

### CWE

Common weakness enumerations covered:
- **CWE-200 - Exposure of Sensitive Information to an Unauthorized Actor**: Metadata leakage exposes sensitive information. This tool demonstrates detection and prevention.
- **CWE-311 - Missing Encryption of Sensitive Data**: While not about encryption, the principle applies. Metadata is sensitive data that shouldn't be shared unprotected.

## Real World Examples

### Case Study 1: John McAfee Location Leak (2012)

When Vice journalists interviewed John McAfee in Guatemala, they posted a photo to their website. The image contained EXIF GPS coordinates revealing McAfee's exact location at a specific timestamp. Security researchers immediately extracted the coordinates and identified the building. Guatemalan authorities used this to locate and detain him.

What happened: The camera automatically embedded GPS data. The journalist didn't think to check EXIF before uploading.

How the attack worked: Simple EXIF extraction with `exiftool photo.jpg` or online services.

What defenses failed: No metadata stripping in the publishing workflow. No EXIF awareness training for journalists.

How this could have been prevented: Running the image through a metadata scrubber before publication. Even a basic `exiftool -all= photo.jpg` would have removed the GPS data.

### Case Study 2: Anonymous PDF Metadata Leak (2012)

Anonymous posted a press release about Operation Megaupload as a PDF. Security researchers examined the metadata and found the author field contained "Officer D'icy Bawlz" (obviously fake) but the metadata also revealed:
- Software: Microsoft Office 2007
- Company: Organización Comunitaria del Barrio de Canónigo
- Creation timestamp with timezone

The company name linked to a specific organization. Cross-referencing with other data points helped narrow down the actual author.

What happened: Creating PDFs in Microsoft Word embeds system metadata by default.

What defenses failed: The author changed the visible author name but didn't check document properties metadata.

## Testing Your Understanding

Before moving to the architecture, make sure you can answer:

1. Why can't you just delete all EXIF tags from a JPEG without breaking the image? (Hint: Orientation and ColorSpace)

2. What's the difference between removing metadata from a JPEG and creating a new JPEG with the same pixel data but no EXIF? (Hint: quality loss from recompression)

3. If a PNG has no EXIF IFD but has tEXt chunks with Author and Copyright fields, will a tool that only removes EXIF clean it properly? (No, it needs to handle textual chunks separately)

If these questions feel unclear, re-read the relevant sections. The implementation will make more sense once these fundamentals click.

## Further Reading

**Essential:**
- EXIF 2.32 specification (JEITA CP-3451F) - Shows exactly what tags exist and their purposes
- PNG specification (ISO/IEC 15948) - Understand chunk structure and ancillary vs critical chunks
- PDF specification (ISO 32000-2) - Document structure and metadata dictionaries

**Deep dives:**
- "No Place to Hide" by Glenn Greenwald - Real-world examples of metadata surveillance
- "The Code Book" by Simon Singh - Historical context of information hiding and exposure
- ExifTool documentation - Best tool for metadata work, read the source

**Historical context:**
- "Reducing Metadata Leakage from Software" (USENIX 2020) - Academic research on automated metadata removal
- "A Picture's Worth: Forensic Implications of Metadata in Digital Images" - Legal and forensic perspectives
