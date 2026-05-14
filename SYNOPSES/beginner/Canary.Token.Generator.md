# Canary Token Generator

## Overview
Build a self-hosted honeytoken system in Go that generates fake credentials (AWS keys, database connection strings, API keys), tripwire documents, and trackable URLs that alert you via webhook when accessed. When an attacker finds and uses these planted tokens, you get an immediate notification with details about who accessed them and from where. This project teaches deception-based defense, a technique used by major security teams to detect breaches that bypass traditional monitoring.

## Step-by-Step Instructions

1. **Understand honeytoken concepts** by studying how security teams plant fake credentials, documents, and URLs throughout their infrastructure as tripwires. When an attacker accesses a honeytoken, it proves a breach occurred because no legitimate user would ever touch them. Research Thinkst Canary Tokens, AWS honey credentials, and how organizations like Netflix use honeytokens in their security programs.

2. **Build a lightweight HTTP server in Go** that serves as the canary token backend. This server generates unique tokens, tracks them in an embedded database (SQLite or BoltDB), and handles incoming callbacks when tokens are triggered. Each token gets a unique identifier and callback URL that phones home when accessed.

3. **Implement credential token types** including fake AWS access keys (matching the AKIA format), database connection strings with embedded tracking, API keys that resolve to your monitoring endpoint, SSH private keys, and .env files containing trackable secrets. Each generated credential must look realistic enough that an attacker would attempt to use it.

4. **Create document and file tokens** such as PDF files with embedded tracking pixels, Word documents with external resource references, Excel files that phone home on open, and text files with unique identifiers. When opened, these files make a callback to your server revealing the opener's IP address, user agent, and timestamp.

5. **Build URL-based tokens** that generate unique tracking URLs disguised as internal admin panels, forgotten API endpoints, or sensitive-looking resources. Implement redirect tokens (redirect to a legitimate page after logging the access), DNS tokens (detect DNS resolution of unique hostnames), and email tokens (unique email addresses that trigger on receive).

6. **Implement the alerting system** with webhook support (Slack, Discord, generic HTTP), email notifications, and a simple web dashboard showing all triggered tokens with details: source IP, geolocation, user agent, timestamp, and which token was triggered. Include severity levels based on token type.

7. **Create deployment tooling** with scripts that scatter tokens across a filesystem, inject them into common locations attackers search (environment variables, config files, cloud credential directories), and a cleanup utility to remove all deployed tokens. Include Docker support for the monitoring server.

8. **Write documentation** explaining the theory of deception-based defense, how to strategically place tokens for maximum detection coverage, integration with incident response workflows, and comparison to commercial canary token services.

## Key Concepts to Learn
- Deception-based defense strategies
- HTTP server development in Go
- Credential format specifications (AWS, API keys)
- Webhook integration and alerting
- IP geolocation and request forensics
- Embedded database management
- Token deployment automation

## Deliverables
- Canary token generation server in Go
- Multiple token types (credentials, documents, URLs, DNS)
- Real-time alerting via webhooks and email
- Web dashboard for monitoring triggered tokens
- Deployment scripts for scattering tokens
- Token cleanup and management utilities
