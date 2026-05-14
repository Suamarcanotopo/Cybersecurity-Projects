# Self-Hosted Shodan Clone

## Overview
Build your own internet-connected device search engine using Go for the scanning backend and React for the web interface. This project replicates the core functionality of Shodan and Censys by scanning IP ranges, fingerprinting running services, detecting software versions, and storing results in a searchable database. You will learn how service fingerprinting actually works at the protocol level, why exposed services are one of the most common attack surfaces, and how security teams use asset discovery to maintain visibility over their infrastructure. Scan only networks you own or have explicit authorization to scan.

## Step-by-Step Instructions
1. **Set up the Go project and scanning architecture** Create a Go module with a worker-pool architecture for concurrent scanning. Use goroutines and channels to manage a configurable number of scanning workers (default 100). Implement a rate limiter using `golang.org/x/time/rate` to cap packets per second and avoid overwhelming networks. Design the scan target system to accept CIDR ranges, individual IPs, and exclusion lists. Store results in PostgreSQL with a schema optimized for search: separate tables for hosts, ports, services, and banners with full-text search indexes. Build a CLI using `cobra` with subcommands for scanning, querying, and managing the database.

2. **Build the TCP port scanner** Implement a SYN-based port scanner using raw sockets (via `gopacket`) for speed, with a TCP connect fallback for environments where raw sockets are not available. Scan the top 1000 most common ports by default, with an option to scan all 65535. Implement service detection based on port number as a first pass (port 22 is likely SSH, port 443 is likely HTTPS), but do not rely on it — the next step adds protocol-level fingerprinting. Handle scan timeouts, retransmissions, and rate limiting. Track scan progress and estimated time remaining. Store raw scan results (IP, port, state, response time) in the database immediately.

3. **Implement protocol-level service fingerprinting** Build protocol handlers for the most common services: HTTP/HTTPS (send a GET request, parse response headers for Server, X-Powered-By, and technology indicators), SSH (parse the banner for software version and supported algorithms), FTP (read the welcome banner), SMTP (read the 220 greeting), MySQL/PostgreSQL (initiate a connection handshake and read the server version), Redis (send INFO command), and MongoDB (send a serverStatus command). Each handler should extract the software name, version, and any configuration details visible in the response. Implement TLS certificate parsing for any TLS-enabled service to extract subject, issuer, expiration, and SANs.

4. **Add technology detection and CPE matching** Build a technology detection engine inspired by Wappalyzer. For HTTP services, analyze response headers, HTML content, JavaScript filenames, cookies, and meta tags to identify frameworks (React, Django, WordPress, Express), web servers (Nginx, Apache, Caddy), and platforms (AWS, Cloudflare, Akamai). Map detected software to CPE (Common Platform Enumeration) identifiers so you can cross-reference with vulnerability databases. Implement signature matching using a JSON-based rules file that is easy to extend with new technology signatures.

5. **Build the search and query engine** Implement a search query language similar to Shodan's: `port:22 country:US`, `product:nginx version:1.18`, `ssl.cert.issuer:LetsEncrypt`, `os:Linux`. Parse queries into PostgreSQL WHERE clauses using a simple recursive descent parser. Support boolean operators (AND, OR, NOT), quoted exact strings, and range queries for ports and dates. Implement faceted search that returns aggregated counts by port, service, technology, and ASN. Optimize query performance with PostgreSQL indexes, materialized views for common aggregations, and result caching in Redis.

6. **Create the React web interface** Build a responsive React frontend with: a search bar supporting the full query language with autocomplete suggestions, a results list showing IP address, open ports, detected services, and technology tags for each host, a detail view for individual hosts showing all ports, banners, TLS certificates, and scan history over time, and a dashboard with aggregate statistics (top ports, top services, newest hosts discovered). Implement result export in JSON and CSV formats. Add a map visualization using Leaflet that plots host locations based on GeoIP data.

7. **Implement continuous scanning and change detection** Build a scheduler that re-scans known hosts on a configurable interval (daily, weekly) and detects changes: new ports opened, ports closed, service version changes, TLS certificate renewals, and new technologies detected. Store the complete scan history for each host so users can see how a service changed over time. Implement alerting via webhook when significant changes are detected (a new port opens, a service version changes to one with known vulnerabilities, a TLS certificate expires). This transforms the tool from a point-in-time scanner into a continuous monitoring platform.

8. **Add vulnerability correlation and write documentation** Cross-reference detected software versions against the NVD (National Vulnerability Database) CVE feed. For each identified service version, query for known CVEs and display them alongside the scan results with severity ratings. Implement a vulnerability dashboard showing the most critical findings across all scanned hosts. Write thorough documentation covering: legal requirements for network scanning (only scan what you own), responsible use policies, deployment architecture, and how to extend the tool with new protocol fingerprinters. Package everything with Docker Compose.

## Key Concepts to Learn
- Network scanning techniques and rate limiting strategies
- Protocol-level service fingerprinting across TCP services
- TLS certificate parsing and analysis
- Technology detection via response analysis and signature matching
- Search query language design and query optimization
- Continuous monitoring and change detection patterns
- CPE identifiers and CVE correlation for vulnerability assessment
- Legal and ethical boundaries of network scanning

## Deliverables
- Go scanning backend with concurrent worker pool and rate limiting
- Protocol fingerprinters for HTTP, SSH, FTP, SMTP, and database services
- Technology detection engine with extensible signature rules
- PostgreSQL search engine with custom query language
- React web UI with search, host detail, dashboard, and map views
- Continuous scanning scheduler with change detection and alerting
- Vulnerability correlation against NVD CVE database
- Docker Compose deployment with complete documentation
