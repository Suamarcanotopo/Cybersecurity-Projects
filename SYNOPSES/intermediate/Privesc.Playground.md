# Privesc Playground

## Overview
Build an intentionally vulnerable Linux environment in Python with 20+ privilege escalation paths that students can discover and exploit in a safe, isolated setting. This project covers the most common real-world privilege escalation vectors found during penetration tests: SUID binaries, sudo misconfigurations, cron job exploitation, writable PATH directories, Docker socket access, capability abuse, and more. You will learn how Linux permission models work at a deep level, why small misconfigurations compound into full system compromise, and how to detect these weaknesses with automated scanning tools like linPEAS and GTFOBins.

## Step-by-Step Instructions
1. **Set up the base environment and container infrastructure** Create a Docker-based lab environment using Python scripts to orchestrate container creation and configuration. Build a base Debian image with common utilities installed (vim, gcc, python3, netcat, curl, wget). Design a user hierarchy: root, a service account, a standard user, and a restricted user. The Python orchestration layer should accept a configuration file (YAML) listing which vulnerability modules to enable, allowing students to customize the difficulty. Build a reset mechanism that destroys and recreates the container to its initial state in under 10 seconds.

2. **Implement SUID and SGID binary vulnerabilities** Create six SUID/SGID-based escalation paths: a custom SUID binary that calls `system()` with a user-controlled argument, a SUID copy of `find` (which can execute commands via `-exec`), a SUID Python interpreter, a SGID binary that writes to a group-writable sensitive file, a SUID binary vulnerable to shared library injection (writable LD_LIBRARY_PATH or RPATH), and a SUID binary that reads files without dropping privileges (allowing /etc/shadow access). For each, write the vulnerable C program, compile it, and set the SUID bit during container setup.

3. **Build sudo misconfiguration vulnerabilities** Configure five sudo-based escalation paths in `/etc/sudoers`: sudo access to `vim` (which allows shell escape), sudo access to `less` with NOPASSWD (shell escape via `!sh`), sudo access to `tar` (command execution via `--checkpoint-action`), sudo access to a custom script that uses unsanitized environment variables, and a wildcard sudo rule (`/opt/scripts/*.sh`) that allows path traversal. Each misconfiguration mirrors real findings from production penetration tests. The Python setup script should modify `/etc/sudoers` programmatically using `visudo` validation.

4. **Implement cron job and scheduled task vulnerabilities** Create four cron-based escalation paths: a root cron job that executes a world-writable script, a cron job that runs with wildcard expansion in a user-writable directory (tar wildcard injection), a cron job that sources a world-writable environment file, and a systemd timer that runs a script from a PATH directory writable by the standard user. Set up the cron jobs during container initialization and create a monitoring page that shows students when cron jobs last ran and what they produced, so they can verify their exploits worked.

5. **Build path and environment variable exploitation** Create four environment-based escalation paths: a root-owned script that calls a binary by name without full path (allowing PATH hijacking), a service that loads a shared library from a user-writable directory, a Python script running as root that imports from a writable `PYTHONPATH`, and a Perl script vulnerable to `@INC` manipulation. Each vulnerability teaches the principle that privilege escalation often comes from controlling the environment in which privileged code executes, not from bugs in the privileged code itself.

6. **Implement container and capability-based escalation** Create three container/capability escalation paths: expose the Docker socket (`/var/run/docker.sock`) to the standard user (allowing container escape to host), grant the `CAP_DAC_READ_SEARCH` capability to a binary (allowing reading any file regardless of permissions), and grant `CAP_SETUID` to a custom binary (allowing UID changes). Also create a scenario where the container runs with `--privileged` flag, allowing mount of the host filesystem. Each scenario should include a brief indicator in the environment that hints at the vulnerability without giving away the exploit.

7. **Build the automated scanning and hint system** Create a Python-based scanning tool that students can run to enumerate potential escalation vectors — a simplified version of linPEAS. The scanner should check: SUID/SGID binaries and cross-reference against GTFOBins, sudo permissions, writable cron scripts, writable PATH directories, Docker socket access, Linux capabilities on binaries, and world-writable sensitive files. For each finding, provide a risk rating and a hint that points toward the exploitation technique without fully revealing it. Include a `--solution` flag that shows the complete exploit for each vector.

8. **Create a progress tracking system and lab guides** Build a progress tracker where each escalation path has a flag (a unique string stored in a file only readable by root or in a specific location). When a student achieves escalation, they submit the flag via a lightweight web API running in the container. Track which flags have been captured and display progress. Write guided lab documentation for each vulnerability category with: the concept explanation, how to discover the vulnerability, exploitation steps, the underlying Linux mechanism being abused, and the fix (what the administrator should have done differently). Package everything with a single `docker compose up` command.

## Key Concepts to Learn
- Linux file permission model: SUID, SGID, sticky bit, and capabilities
- Sudo configuration syntax and common misconfiguration patterns
- Cron job security and the risks of wildcard expansion
- PATH hijacking and environment variable manipulation
- Container security: Docker socket exposure and privileged mode risks
- GTFOBins and living-off-the-land binary exploitation
- Privilege escalation enumeration methodology
- Defense hardening: how to prevent each escalation vector

## Deliverables
- Docker-based vulnerable Linux environment with 20+ escalation paths
- Python orchestration layer with YAML-based vulnerability selection
- Six SUID/SGID vulnerabilities with compiled C binaries
- Five sudo misconfiguration scenarios
- Four cron job and four environment variable exploitation paths
- Container escape and capability abuse scenarios
- Automated scanning tool with GTFOBins cross-reference
- Flag-based progress tracking system with guided lab documentation
