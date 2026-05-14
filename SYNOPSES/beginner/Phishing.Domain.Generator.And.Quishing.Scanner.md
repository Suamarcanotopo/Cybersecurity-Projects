# Phishing Domain Generator & Quishing Scanner

## Overview
Build a dual-purpose phishing detection tool that generates every possible typosquat variant of a legitimate domain (homoglyphs, bit-flips, keyboard adjacency, TLD swaps) and checks which variants are actually registered, combined with a QR code phishing ("quishing") scanner that analyzes QR codes for malicious destinations. This project covers both traditional domain-based phishing and the rapidly growing QR phishing vector that exploded in 2024-2025.

## Step-by-Step Instructions

1. **Understand domain-based phishing techniques** including typosquatting (gooogle.com), homoglyph attacks (using Cyrillic characters that look identical to Latin—аpple.com vs apple.com), bit-flipping (domains reachable via single-bit DNS errors), keyboard adjacency substitution (gmai.com), TLD variations (.com vs .co), and subdomain abuse (apple.com.evil.com). Research IDN homograph attacks and how browsers handle internationalized domain names.

2. **Build the domain variant generator** that takes a legitimate domain and produces every possible typosquat permutation: character omission, character repetition, character swap, adjacent keyboard substitution, homoglyph replacement (with a comprehensive Unicode confusable database), bit-flip variants, TLD swaps across common TLDs, and hyphenation variants. This can produce thousands of candidates for a single domain.

3. **Implement registration checking** that tests which generated domain variants are actually registered using DNS resolution, WHOIS lookups, and certificate transparency log searches. Rate-limit queries to avoid being blocked, implement concurrent lookups for speed, and cache results. Flag registered domains with risk scoring based on how visually similar they are to the legitimate domain.

4. **Add domain intelligence enrichment** for registered typosquats: WHOIS registration date (recently registered domains are more suspicious), hosting provider, SSL certificate details, website content similarity comparison, and presence in known phishing databases (PhishTank, OpenPhish). Generate a threat report ranking discovered typosquats by risk level.

5. **Build the QR code phishing scanner** that decodes QR codes from images or camera input and analyzes the embedded URL for phishing indicators: domain reputation, URL shortener detection and expansion, redirect chain following, homoglyph detection in the destination domain, and comparison against known phishing databases. Implement batch scanning for analyzing multiple QR codes from photos of public spaces.

6. **Create QR code generation for testing** that produces QR codes demonstrating various quishing techniques: URL shortener obfuscation, redirect chains, data URI abuse, and Unicode tricks. These test QR codes help security teams understand what malicious QR codes look like and train employees to be suspicious.

7. **Build a CLI interface with reporting** that supports single-domain analysis, batch domain monitoring, QR image scanning, and generates reports in multiple formats (JSON, HTML, CSV) showing all discovered threats with evidence and risk scores. Include a watch mode that periodically re-checks domains for new registrations.

8. **Document real-world phishing campaigns** that used these techniques, including the 2023 Microsoft QR phishing campaign, homoglyph attacks against cryptocurrency exchanges, and typosquatting campaigns targeting npm/PyPI package names. Explain defensive measures including DMARC, browser IDN policies, and QR code verification best practices.

## Key Concepts to Learn
- Domain name system and typosquatting techniques
- Unicode homoglyph and IDN attacks
- QR code structure and error correction
- DNS resolution and WHOIS queries
- Phishing detection and threat intelligence APIs
- Certificate transparency logs
- Batch processing and concurrent I/O

## Deliverables
- Comprehensive typosquat domain variant generator
- Registration checker with DNS/WHOIS/CT lookups
- Domain intelligence enrichment and risk scoring
- QR code phishing scanner with URL analysis
- Test QR code generator for security awareness
- CLI with reporting (JSON, HTML, CSV)
- Watch mode for continuous monitoring
