# Linux eBPF Security Tracer

## Overview
Build a real-time security monitoring tool using eBPF (extended Berkeley Packet Filter) with Python and C that traces system calls, detects suspicious process behavior, monitors file integrity, and tracks network connections at the kernel level. Using the BCC (BPF Compiler Collection) framework, this project attaches eBPF programs to kernel events to provide deep observability without modifying the kernel or installing kernel modules. This teaches the most modern Linux security observability technology used by tools like Falco, Cilium, and Tetragon.

## Step-by-Step Instructions

1. **Understand eBPF fundamentals** by learning how eBPF programs run sandboxed inside the Linux kernel, triggered by events like system calls, function entries, and network events. Unlike kernel modules, eBPF programs are verified for safety before loading and cannot crash the kernel. Study the BCC framework which lets you write eBPF programs in C and control them from Python.

2. **Implement system call tracing** by attaching eBPF kprobes to security-relevant syscalls: execve (process execution), open/openat (file access), connect (network connections), ptrace (process debugging/injection), and clone/fork (process creation). Capture the calling process, arguments, return values, and timestamps for each traced syscall.

3. **Build process execution monitoring** that logs every new process spawned on the system with its full command line, parent process, user ID, and working directory. Detect suspicious patterns: processes spawned by web servers (potential RCE), shells spawned by non-interactive services, and processes attempting to delete themselves after execution.

4. **Implement file access monitoring** by tracing open/openat/unlink syscalls for sensitive paths: /etc/passwd, /etc/shadow, SSH keys, cron directories, and systemd unit paths. Alert when unexpected processes access these files, detecting potential credential theft, persistence installation, or configuration tampering.

5. **Add network connection tracking** by tracing connect() and accept() syscalls to log all outbound and inbound connections with source/destination IPs, ports, and the process responsible. Flag connections to known-bad IP ranges, unusual ports, or connections from processes that shouldn't be making network requests (like cron or systemd-resolved connecting to non-DNS ports).

6. **Create privilege escalation detection** by monitoring setuid/setgid syscalls, capability changes, and transitions from unprivileged to privileged execution. Detect when processes gain unexpected privileges, when SUID binaries are executed, or when capabilities are added to running processes.

7. **Build a TUI dashboard** using Rich or similar library that displays live security events in a scrolling log, maintains counters for different event types, highlights critical alerts, and allows filtering by event type, process name, or severity. Include a summary panel showing the most active processes, most accessed sensitive files, and most frequent network destinations.

8. **Write documentation** explaining eBPF architecture, how the BCC framework bridges kernel C and Python userspace, performance considerations for production use, and comparison to other monitoring approaches (auditd, inotify, strace). Include guidance on which syscalls to trace for different threat models.

## Key Concepts to Learn
- eBPF program architecture and safety model
- BCC framework for kernel tracing
- System call interface and security implications
- Process execution and privilege monitoring
- File access auditing at the kernel level
- Network connection tracking
- Real-time event processing and alerting

## Deliverables
- eBPF programs for syscall tracing (C)
- Python control plane with BCC integration
- Process execution and privilege escalation detection
- File access monitoring for sensitive paths
- Network connection tracking and alerting
- TUI dashboard with live security events
