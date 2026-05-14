# Steganography Multi-Tool

## Overview
Build a multi-format steganography toolkit that hides secret data across six different media types: images (LSB encoding), audio files (WAV/FLAC sample manipulation), QR codes (error correction exploitation), PDFs (whitespace and invisible text layers), plaintext (zero-width Unicode characters), and git commits (timestamp and whitespace encoding). This project teaches data encoding across diverse file formats and demonstrates that covert communication extends far beyond hiding text in pictures.

## Step-by-Step Instructions

1. **Implement image steganography as the foundation** using PIL/Pillow to manipulate pixel data with least significant bit encoding. Support PNG and BMP formats (lossless compression preserves hidden data). Build a capacity calculator showing maximum payload size per image, and include AES encryption of the payload before embedding so extraction without the key yields only noise.

2. **Add audio steganography support** for WAV and FLAC files by encoding data in the least significant bits of audio samples. Audio files contain far more data capacity than images—a 30-second WAV at 44.1kHz stereo holds millions of samples. Implement sample-level LSB replacement while maintaining audio quality imperceptible to human ears, and verify the output file plays identically to the original.

3. **Build QR code steganography** by exploiting QR error correction redundancy. QR codes use Reed-Solomon error correction allowing up to 30% data damage at the highest level—embed hidden data in the error correction bits so the QR still scans to its original URL but carries a secret payload extractable by your tool.

4. **Implement zero-width Unicode text steganography** using invisible characters (zero-width space U+200B, zero-width non-joiner U+200C, zero-width joiner U+200D) embedded between visible characters. The output looks like normal text in Discord, Slack, or any messaging platform, but contains a hidden binary message encoded in the pattern of invisible characters.

5. **Add PDF steganography** using multiple techniques: whitespace encoding between words (varying space width imperceptibly), invisible text layers with font size zero or matching background color, and metadata field manipulation. Support both hiding data in existing PDFs and extracting hidden data from suspicious documents.

6. **Create git commit steganography** that encodes messages in commit metadata: manipulate author timestamps (encoding bits in the seconds field), insert specific whitespace patterns in commit messages, or use author name variations. Build both an encoder that creates commits with hidden messages and a decoder that extracts them from repository history.

7. **Build a unified CLI interface** with subcommands for each format (encode/decode per type), automatic format detection for decoding, a universal encryption layer that wraps all formats, and batch processing support. Include a capacity report showing how much data each input file can hold and recommend the optimal format for a given payload size.

8. **Create comprehensive documentation** covering the theory behind each steganography technique, detection methods (steganalysis) for each format, real-world use cases of steganography in espionage and whistleblowing, and the limitations of each approach. Include examples demonstrating that the modified files are perceptually identical to originals.

## Key Concepts to Learn
- Least significant bit manipulation across media types
- Audio sample encoding and WAV/FLAC file structure
- QR code error correction and Reed-Solomon codes
- Unicode invisible characters and text encoding
- PDF internal structure and manipulation
- Symmetric encryption integration (AES)
- File format parsing and binary I/O

## Deliverables
- Image steganography encoder/decoder (PNG, BMP)
- Audio steganography for WAV/FLAC files
- QR code payload embedding via error correction
- Zero-width Unicode text steganography
- PDF steganography with multiple techniques
- Git commit metadata encoding
- Unified CLI with encryption and batch processing
