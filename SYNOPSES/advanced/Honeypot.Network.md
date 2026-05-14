# Honeypot Network

## Overview
Build a network of realistic honeypots in Go that simulate SSH, HTTP, FTP, SMB, MySQL, and Redis services, capturing and analyzing attacker behavior in detail. The system logs all interactions including commands executed, files uploaded, credentials attempted, and lateral movement attempts, then fingerprints attacker tools and techniques, maps activity to the MITRE ATT&CK framework, and generates IOCs (indicators of compromise) from captured sessions. A web dashboard provides real-time visibility into attacker activity, geographic distribution, and TTP analysis. This project teaches deception technology, attacker tradecraft analysis, and the architecture behind commercial honeypot platforms like T-Pot and Cowrie.

## Step-by-Step Instructions

1. **Design the honeypot network architecture** with each service type implemented as an independent Go module sharing a common logging and analysis backend. Build a central event bus that collects interaction data from all honeypots, normalizes events into a unified schema (timestamp, source IP, service type, action, payload), and stores them in PostgreSQL with Elasticsearch for full-text search. Design the system for easy deployment of multiple honeypot instances across different network segments.

2. **Implement the SSH honeypot** as the highest-value sensor, emulating an OpenSSH server that accepts any credential combination while logging all attempts. After authentication, provide a realistic-looking shell environment with a fake filesystem, common commands (ls, cat, wget, curl, whoami, uname), and simulated system responses. Record full session transcripts including every command entered, files downloaded, and lateral movement attempts (ssh to other hosts).

3. **Build the HTTP honeypot** presenting vulnerable-looking web applications: a fake WordPress admin panel, phpMyAdmin interface, exposed API endpoints, and common web shell paths. Log all requests with full headers, POST bodies, and uploaded files. Detect and classify automated scanning tools (Nikto, Nmap NSE scripts, SQLmap) by their request patterns and user-agent strings.

4. **Create service-specific honeypots for FTP, SMB, MySQL, and Redis** each emulating enough protocol to engage attackers. FTP: accept anonymous and credential logins, log file upload/download attempts. SMB: respond to share enumeration, log authentication attempts and EternalBlue-style exploit attempts. MySQL: accept connections, log queries and credential attempts. Redis: respond to INFO and CONFIG commands, detect cryptominer deployment attempts (a common Redis attack pattern).

5. **Build the attacker fingerprinting engine** that correlates activity across all honeypot types to build attacker profiles: group interactions by source IP and session timing, identify tools used (Metasploit, Cobalt Strike, custom scripts) by behavioral signatures, classify attacker sophistication (automated scanner vs manual attacker vs APT), and track attacker progression through the kill chain (reconnaissance, exploitation, post-exploitation, lateral movement).

6. **Implement MITRE ATT&CK mapping** that automatically classifies each observed technique: credential brute force (T1110), command and scripting interpreter (T1059), ingress tool transfer (T1105), account discovery (T1087), and more. Build a heat map showing which ATT&CK techniques are most commonly observed, trending techniques over time, and technique chains (which techniques are commonly used together).

7. **Create the IOC extraction and export system** that generates actionable threat intelligence from honeypot data: extract IP addresses, domains, file hashes (of uploaded malware), SSH keys, credential lists, and command patterns. Export in STIX/TAXII format for integration with threat intelligence platforms, generate YARA rules from captured malware samples, and produce blocklists for firewall integration.

8. **Build the web dashboard** showing real-time attack activity: a world map with active attacker locations, per-service interaction graphs, top attacker IPs with profile cards, ATT&CK heat map, credential wordcloud from attempted passwords, timeline of notable sessions (manual attackers, novel techniques), and IOC feeds. Include a session replay feature that plays back SSH sessions command-by-command for analysis.

## Key Concepts to Learn
- Honeypot design and protocol emulation
- Network service protocols (SSH, HTTP, FTP, SMB, MySQL, Redis)
- Attacker behavior analysis and profiling
- MITRE ATT&CK framework mapping
- IOC extraction and STIX/TAXII export
- Go concurrent service architecture
- Threat intelligence generation
- Deception technology deployment

## Deliverables
- Six service honeypots (SSH, HTTP, FTP, SMB, MySQL, Redis)
- Central event collection and analysis backend
- Attacker fingerprinting and session correlation
- MITRE ATT&CK automatic technique mapping
- IOC extraction with STIX/TAXII and YARA export
- Web dashboard with real-time attack visualization
- SSH session replay for manual analysis
- Blocklist generation for defensive integration
