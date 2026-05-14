# DNS Sinkhole

## Overview
Build a Pi-hole-style DNS sinkhole in Go that acts as a custom DNS server blocking malware domains, ad trackers, and known C2 (command and control) servers using community-maintained blocklists. The tool features blocklist management with automatic updates, query logging with analytics, whitelist/blacklist configuration, and a live web dashboard showing blocked queries, top blocked domains, and query statistics. This project teaches DNS protocol internals, network-level defense, and how DNS filtering protects entire networks at the resolution layer.

## Step-by-Step Instructions

1. **Understand DNS resolution and sinkhole concepts** by studying how DNS resolves domain names to IP addresses, how recursive and authoritative DNS servers work, and how a sinkhole intercepts DNS queries to return false results for blocked domains. Research Pi-hole's architecture, the DNS protocol (RFC 1035), and common blocklist formats (hosts file, domain list, ABP filter syntax).

2. **Implement a DNS server in Go** using a DNS library that listens on port 53 (UDP and TCP), parses incoming DNS queries, and responds with either legitimate answers (forwarded to upstream resolvers like 1.1.1.1 or 8.8.8.8) or sinkhole responses (0.0.0.0 or NXDOMAIN) for blocked domains. Handle common record types: A, AAAA, CNAME, MX, and TXT.

3. **Build the blocklist engine** that downloads and parses community blocklists (Steven Black's unified hosts, various malware domain lists, ad server lists, C2 domain lists) into an efficient in-memory data structure (trie or hash map) for fast O(1) lookups. Implement automatic blocklist updates on a configurable schedule, deduplication across multiple lists, and wildcard domain blocking.

4. **Add whitelist and custom blacklist support** allowing users to override blocklist decisions: whitelist domains that are incorrectly blocked (false positives), add custom blacklist entries for domains not in community lists, and support regex-based rules for flexible matching. Store configuration in a simple YAML or TOML file.

5. **Implement query logging and analytics** that records every DNS query with timestamp, source IP, queried domain, response type (blocked/allowed/cached), and upstream response time. Store logs in SQLite for querying. Calculate statistics: total queries, percentage blocked, top queried domains, top blocked domains, queries per client, and queries over time.

6. **Build a web dashboard** using Go's net/http with embedded static files that displays real-time query statistics, a live query log, top blocked/allowed domains charts, per-client statistics, and blocklist management (enable/disable lists, force updates, view block counts per list). Include a search function to check if a specific domain would be blocked and by which list.

7. **Add caching and performance optimization** with a DNS response cache that stores upstream answers with proper TTL handling, reducing latency and upstream query volume. Implement concurrent query processing, connection pooling to upstream resolvers, and benchmark the system to ensure it can handle household-level query volume without noticeable latency.

8. **Create deployment documentation** with setup instructions for configuring the sinkhole as a network's primary DNS server (router DHCP settings), Docker deployment option, systemd service configuration, and Raspberry Pi-specific instructions. Include troubleshooting guides for common issues like DNS loops and broken website functionality.

## Key Concepts to Learn
- DNS protocol and resolution process
- DNS sinkhole and filtering concepts
- Efficient data structures for domain lookup
- Community blocklist ecosystems
- Go HTTP server and web dashboard development
- DNS caching and TTL management
- Network-level defense strategies

## Deliverables
- DNS server in Go with sinkhole capability
- Community blocklist downloading and parsing
- Whitelist/blacklist with regex support
- Query logging with SQLite storage
- Web dashboard with real-time statistics
- DNS response caching with TTL
- Docker and systemd deployment support
