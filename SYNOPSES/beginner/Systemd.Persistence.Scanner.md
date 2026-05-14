# Systemd Persistence Scanner

## Overview
Build a Linux persistence mechanism hunter in Go that scans every known location where attackers plant backdoors to survive reboots: cron jobs, systemd services and timers, shell RC files, SSH authorized_keys, LD_PRELOAD hijacking, kernel modules, udev rules, at jobs, XDG autostart entries, init.d scripts, and MOTD scripts. The tool compiles to a single portable binary that can be dropped onto any Linux system for immediate threat hunting. This project teaches post-compromise forensics and the dozens of ways attackers maintain access to compromised systems.

## Step-by-Step Instructions

1. **Research Linux persistence mechanisms** by studying how attackers maintain access after initial compromise. Each mechanism represents a different autorun location: cron executes on schedule, systemd services start at boot, shell RC files execute on login, authorized_keys allows passwordless SSH, LD_PRELOAD injects code into every process, kernel modules load at boot with root privileges, and udev rules trigger on hardware events.

2. **Implement cron job scanning** by parsing all cron locations: user crontabs (/var/spool/cron/), system crontab (/etc/crontab), cron directories (/etc/cron.d/, /etc/cron.daily/, /etc/cron.hourly/, /etc/cron.weekly/, /etc/cron.monthly/), and anacron jobs. Flag suspicious entries: base64-encoded commands, curl/wget piped to shell, reverse shell patterns, and references to world-writable directories.

3. **Build systemd service and timer scanning** that enumerates all systemd unit files across standard paths (/etc/systemd/system/, /usr/lib/systemd/system/, ~/.config/systemd/user/), identifies non-package-managed units (not owned by any installed package), and flags suspicious ExecStart commands, unusual After/Wants dependencies, and timer units with frequent triggers.

4. **Scan shell initialization files** including /etc/profile, /etc/profile.d/*, ~/.bashrc, ~/.bash_profile, ~/.zshrc, ~/.profile, and /etc/bash.bashrc for injected commands. Detect obfuscated payloads, encoded strings, network connections, file downloads, and commands that don't match typical shell configuration patterns.

5. **Check SSH configuration and keys** by scanning authorized_keys files for all users, detecting keys with forced commands (command= option), identifying keys added recently, checking for SSH config modifications (authorized_keys path changes, PermitRootLogin modifications), and scanning for SSH backdoors in /etc/ssh/sshd_config.

6. **Implement advanced persistence checks** including: LD_PRELOAD entries in /etc/ld.so.preload and environment variables, kernel module enumeration compared against package manager (unsigned/unknown modules), udev rules in /etc/udev/rules.d/ with RUN commands, at job queue inspection, XDG autostart entries, init.d scripts, and MOTD/update-motd.d scripts that execute on login.

7. **Build risk scoring and output formatting** where each finding gets a severity score based on the persistence technique, obfuscation level, and whether it matches known attack patterns. Output results with color-coded terminal display, JSON for programmatic consumption, and a summary showing total findings by severity with recommended investigation priority.

8. **Add baseline comparison mode** that saves a snapshot of all persistence mechanisms on a known-clean system, then on subsequent runs highlights only differences from baseline. This dramatically reduces noise on systems with many legitimate cron jobs and services, focusing attention on newly added persistence.

## Key Concepts to Learn
- Linux persistence mechanisms (MITRE ATT&CK Persistence)
- Systemd unit file structure and management
- Cron job configuration and scheduling
- SSH key authentication and configuration
- LD_PRELOAD and library injection
- Go cross-compilation for portable binaries
- Threat hunting and forensic analysis

## Deliverables
- Single compiled Go binary for portability
- Scanning for 12+ persistence mechanism types
- Suspicious pattern detection with risk scoring
- Color-coded terminal output and JSON export
- Baseline snapshot and comparison mode
- Package manager verification for installed files
