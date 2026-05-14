# Trojan Application Builder

## Overview
Build an educational malware lifecycle demonstration in Python that creates a convincing-looking application (a fake game launcher with AI-generated artwork) which secretly exfiltrates data from a dummy database and simulates file encryption. The project includes a small FastAPI backend with fake user data as the victim environment, demonstrating the complete attack chain from social engineering through data exfiltration to ransomware-style encryption—all in a self-contained, clearly-educational sandbox. This project teaches malware anatomy, social engineering, and defensive awareness.

## Step-by-Step Instructions

1. **Build the victim environment** using FastAPI with a SQLite database containing fake user data (generated names, emails, hashed passwords, payment tokens). This simulates a real application's backend that the trojan will target. Include a simple web interface showing the "legitimate" application is running with its database of users.

2. **Create the trojan application** as a Python GUI program using tkinter or PyQt that presents itself as a game launcher with an attractive interface (use AI-generated artwork for the splash screen). The application should look and feel legitimate—include fake loading bars, menu options, and a "Play" button that appears functional.

3. **Implement data exfiltration capabilities** that activate alongside the visible GUI: scan for database files (SQLite, PostgreSQL connection strings in environment variables), extract credentials from common locations (.env files, config files, browser password stores in the demo environment), and package the stolen data for transmission.

4. **Add simulated file encryption** demonstrating ransomware behavior: enumerate files in a designated sandbox directory (never touch real user files), encrypt them using AES with a generated key, rename files with a custom extension, and generate a ransom note. Implement a decryption mode that restores files using the key, demonstrating the full ransomware lifecycle.

5. **Build the command and control callback** where the trojan sends exfiltrated data and encryption keys to a local listener (simulating C2 communication). Implement basic encoding of the exfiltration payload, periodic heartbeat messages, and command reception. Keep all traffic local—never connect to external servers.

6. **Create detection and analysis tooling** that accompanies the trojan: a process monitor showing what the trojan is actually doing (file access, network connections, database queries), a network capture showing C2 traffic patterns, and a behavioral analysis report documenting each malicious action with timestamps.

7. **Implement defensive countermeasures demonstration** showing how each stage of the attack could be detected or prevented: endpoint detection for suspicious file access patterns, network monitoring for C2 callback patterns, database access auditing, and file integrity monitoring that catches the encryption stage.

8. **Write extensive ethical documentation** with prominent warnings that this is educational only, never to be deployed against real systems. Cover the legal framework around malware development (CFAA, Computer Misuse Act), the ethics of security research, and how understanding malware anatomy helps defenders build better detection.

## Key Concepts to Learn
- Trojan horse malware anatomy and behavior
- Social engineering and deceptive interfaces
- Data exfiltration techniques and patterns
- File encryption and ransomware mechanics
- Command and control communication
- Behavioral malware analysis
- Endpoint detection and response concepts

## Deliverables
- Fake game launcher GUI with trojan capabilities
- FastAPI victim environment with dummy database
- Data exfiltration and credential harvesting
- Sandbox file encryption with decryption mode
- Local C2 server and callback mechanism
- Detection and analysis companion tooling
- Comprehensive ethical usage documentation
