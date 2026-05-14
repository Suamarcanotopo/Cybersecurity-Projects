# DLP Scanner

## Overview
Build a Data Loss Prevention scanner in Python that detects sensitive data across filesystems, databases, and network traffic by matching patterns for PII, financial data, healthcare records, API keys, and custom-defined secrets. This project teaches how enterprise DLP systems work under the hood — the same pattern matching, contextual analysis, and classification logic used by tools like Symantec DLP, Microsoft Purview, and open-source alternatives. You will generate compliance reports mapped to GDPR, HIPAA, and PCI-DSS requirements, making this tool practical for real security audits.

## Step-by-Step Instructions
1. **Set up the Python project and scanner architecture** Initialize a Python project with `uv` and design a modular scanner architecture with three input adapters (filesystem, database, network), a shared detection engine, and multiple output formatters (JSON, CSV, PDF). Define a `ScanTarget` abstract class that each adapter implements, providing a `stream_content()` method that yields chunks of text with source metadata (file path, table name, packet info). This abstraction lets the same detection engine work across all data sources. Use `pydantic` for configuration models and scan result structures.

2. **Build the pattern detection engine** Implement a multi-strategy detection engine that combines regex matching, checksum validation, and contextual analysis. For regex, build patterns for: Social Security numbers (with and without dashes, validated against known invalid ranges), credit card numbers (Visa, Mastercard, Amex, Discover with Luhn checksum validation), phone numbers (US and international formats), email addresses, dates of birth, and passport numbers. For API keys, build patterns matching known formats: AWS access keys (AKIA prefix), GitHub tokens (ghp_ prefix), Stripe keys (sk_live_ prefix), and generic high-entropy strings. Each pattern should have a confidence score reflecting how likely the match is a true positive.

3. **Implement the filesystem scanner** Build a filesystem adapter that recursively scans directories while respecting exclusion patterns (skip `.git`, `node_modules`, `__pycache__`, binary files). Support common file formats: plain text, CSV, JSON, XML, YAML, PDF (using `pdfminer`), Word documents (using `python-docx`), Excel spreadsheets (using `openpyxl`), and compressed archives (zip, tar.gz). For each file, extract text content, run it through the detection engine, and record findings with the exact file path, line number, column position, and a redacted preview of the match. Implement parallel scanning using `concurrent.futures` to handle large directory trees efficiently.

4. **Build the database scanner** Create a database adapter that connects to PostgreSQL, MySQL, and SQLite databases, enumerates all tables and columns, samples data from each column (configurable sample size, default 1000 rows), and runs the detection engine on sampled values. Implement column-level classification: if more than a configurable threshold of sampled values match a pattern, classify the entire column as containing that data type. Generate a data map showing which tables and columns contain sensitive data and what type. Support connection via connection string or environment variable. Handle large databases by scanning in batches to avoid memory issues.

5. **Implement the network traffic scanner** Build a network adapter using `scapy` that captures live traffic or reads PCAP files and extracts text content from unencrypted protocols: HTTP request/response bodies, SMTP email content, FTP commands and data transfers, and DNS query names. Run extracted content through the detection engine to identify sensitive data in transit. Flag any sensitive data found in unencrypted traffic as a critical finding since it indicates data exposure. For encrypted traffic, note the protocol and destination but do not attempt decryption — the finding here is confirming that sensitive data paths are encrypted.

6. **Build the contextual analysis and false positive reduction system** Implement contextual analysis that examines the surrounding text to improve classification accuracy. A nine-digit number near the word "SSN" or "Social Security" has higher confidence than one in isolation. A sixteen-digit number in a test file containing "4111111111111111" is likely test data, not a real card number. Build a false positive suppression system: maintain an allowlist of known test values, known safe file paths, and patterns that appear in code comments or documentation. Support user feedback where a finding can be marked as false positive and the system remembers it for future scans.

7. **Create compliance report generators** Build report generators for three compliance frameworks: GDPR (identify personal data processing locations, data subject categories, and cross-border data flows), HIPAA (detect PHI including patient names near medical record numbers, diagnosis codes, and prescription information), and PCI-DSS (locate cardholder data environments and verify they are within defined CDE boundaries). Each report maps findings to specific regulation articles or requirements (e.g., GDPR Article 30 records of processing, PCI-DSS Requirement 3 stored cardholder data). Output reports in PDF with executive summary, detailed findings, and remediation recommendations.

8. **Add scheduling, alerting, and integration testing** Implement a scan scheduler that runs periodic scans (daily, weekly) and tracks changes over time: new sensitive data found, previously found data remediated, and trend lines showing data exposure over weeks. Send alerts via webhook when critical findings are detected (credit card numbers in logs, SSNs in publicly accessible directories). Write integration tests using Docker Compose that set up PostgreSQL with planted sensitive data, a filesystem with test documents containing known patterns, and verify the scanner finds all planted data with the correct classification. Measure false positive and false negative rates against the test dataset.

## Key Concepts to Learn
- Regular expression design for sensitive data pattern matching
- Luhn checksum and other data validation algorithms
- Data classification methodology and confidence scoring
- False positive reduction through contextual analysis
- GDPR, HIPAA, and PCI-DSS data protection requirements
- Network traffic analysis for data loss detection
- Compliance reporting and audit trail generation
- Scheduled scanning and trend analysis for security posture tracking

## Deliverables
- Python DLP scanner with filesystem, database, and network adapters
- Pattern detection engine with 15+ sensitive data patterns and validation
- Contextual analysis system with false positive reduction
- Compliance report generators for GDPR, HIPAA, and PCI-DSS
- Scan scheduler with trend tracking and webhook alerting
- Docker Compose integration test suite with planted sensitive data
- PDF report output with executive summary and remediation guidance
