# Keylogger

## What This Is

A cross-platform keylogger that captures keyboard events, tracks active windows, and delivers logs remotely via webhooks. Built with Python using pynput for event capture, this demonstrates how malware monitors user activity and exfiltrates data without detection.

## Why This Matters

Keyloggers are one of the oldest and most effective attack vectors. They've been used in major breaches including the 2013 Target breach where attackers used keylogging malware on point-of-sale systems to steal 40 million credit cards. Corporate espionage frequently relies on keyloggers to steal credentials, intellectual property, and sensitive communications.

**Real world scenarios where this applies:**
- Credential theft: Attackers deploy keyloggers to capture login credentials for banking, email, and corporate systems. The 2017 Equifax breach started with stolen credentials that could have been captured this way.
- Corporate espionage: Nation-state actors use keyloggers to monitor executives and steal trade secrets. The 2015 Anthem breach involved keylogging components that helped attackers pivot through the network.
- Insider threats: Malicious insiders or investigators use keyloggers to monitor employees, sometimes legally for compliance, sometimes illegally for blackmail or competitive advantage.

## What You'll Learn

This project teaches you how keyboard capture malware works under the hood. By building it yourself, you'll understand:

**Security Concepts:**
- Keyboard event interception: How operating systems expose keyboard events to applications and why this creates a security boundary that's difficult to protect
- Data exfiltration patterns: The techniques malware uses to send stolen data to command-and-control servers, including batching to avoid detection
- Cross-platform malware development: Platform-specific APIs for Windows (win32gui), macOS (AppKit), and Linux (xdotool) that malware exploits

**Technical Skills:**
- Event-driven programming with callbacks that process keyboard input in real time
- Thread-safe logging using locks to prevent race conditions when multiple threads access shared resources
- Platform detection and conditional imports to create malware that adapts to different operating systems
- File rotation strategies to manage log sizes and avoid filling up disk space

**Tools and Techniques:**
- pynput library for low-level keyboard and mouse event capture
- Webhook delivery for remote data exfiltration over HTTPS
- Process and window tracking to correlate keystrokes with the applications they were typed into

## Prerequisites

Before starting, you should understand:

**Required knowledge:**
- Python fundamentals including classes, dataclasses, enums, and type hints (the code uses modern Python 3.13 features)
- Basic threading concepts like locks and events for synchronization
- File I/O operations and path manipulation with pathlib
- How HTTP POST requests work (for webhook delivery)

**Tools you'll need:**
- Python 3.13 or later
- uv package manager (install with `curl -LsSf https://astral.sh/uv/install.sh | sh`)
- Terminal access with permissions to install packages

**Helpful but not required:**
- Understanding of operating system process models and how applications interact with the OS
- Familiarity with defensive security concepts like EDR (Endpoint Detection and Response)
- Knowledge of JSON for understanding webhook payload structure

## Quick Start

Get the project running locally:

```bash
# Clone and navigate
cd PROJECTS/beginner/keylogger

# Setup virtual environment and dependencies
just setup

# Activate virtual environment
source .venv/bin/activate  # Linux/macOS
.venv\Scripts\activate     # Windows

# Run tests to verify setup
just test

# Run the keylogger (WARNING: Only on systems you own)
python keylogger.py
```

Expected output:
```
Keylogger Started

Log Directory: /home/user/.keylogger_logs
Current Log: keylog_20250131_143022_451283.txt
Toggle Key: F9
Webhook: Disabled

[*] Press F9 to start/stop logging
[*] Press CTRL+C to exit
```

Once running, type some test text. Check `~/.keylogger_logs/` for the captured keystrokes. Press F9 to pause/resume logging, CTRL+C to exit gracefully.

## Project Structure

```
keylogger/
├── keylogger.py          # Main implementation (~540 lines)
├── test_keylogger.py     # 46 pytest tests
├── pyproject.toml        # Dependencies and linting configuration
├── justfile              # Build automation commands
└── .keylogger_logs/      # Created at runtime for log storage
    └── keylog_*.txt      # Timestamped log files
```

## Next Steps

1. **Understand the concepts** - Read [01-CONCEPTS.md](./01-CONCEPTS.md) to learn about keyboard capture, data exfiltration, and detection evasion
2. **Study the architecture** - Read [02-ARCHITECTURE.md](./02-ARCHITECTURE.md) to see the component design and data flow
3. **Walk through the code** - Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for line-by-line implementation details
4. **Extend the project** - Read [04-CHALLENGES.md](./04-CHALLENGES.md) for ideas like adding encryption or screenshot capture

## Common Issues

**ImportError: pynput is required**
```
ImportError: pynput is required: uv add pynput
```
Solution: Run `just setup` to install all dependencies via uv. The project requires pynput 1.8.1 for keyboard capture.

**Window tracking returns None on Linux**
Solution: Install xdotool with `sudo apt-get install xdotool` (Debian/Ubuntu) or `sudo dnf install xdotool` (Fedora). Without it, window titles won't be captured but keystroke logging still works.

**Permission denied when creating log directory**
Solution: The keylogger creates `~/.keylogger_logs` in your home directory. If this fails, check filesystem permissions or modify `KeyloggerConfig.log_dir` to point elsewhere.

**Webhook delivery fails with connection timeout**
Solution: If you set a webhook_url in the config, ensure the endpoint is reachable and accepts POST requests. The webhook is optional, local logging works without it.

## Related Projects

If you found this interesting, check out:
- **Process Monitor** - Similar OS interaction patterns for tracking process creation and termination
- **Network Sniffer** - Different data exfiltration techniques using packet capture instead of keyboard events
- **Rootkit** - More advanced stealth techniques like hiding processes and files from detection
