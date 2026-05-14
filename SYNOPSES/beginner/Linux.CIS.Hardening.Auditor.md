# Linux CIS Hardening Auditor

## Overview
Build a comprehensive CIS (Center for Internet Security) benchmark compliance checker written entirely in Bash that audits a Linux system against Level 1 and Level 2 security benchmarks. The tool checks SSH configuration, firewall rules, file permissions, user accounts, kernel parameters, running services, and filesystem mounts, generating a scored compliance report with pass/fail/warn results for each control. This project teaches system hardening, compliance frameworks, and advanced Bash scripting through real security assessment.

## Step-by-Step Instructions

1. **Study the CIS benchmark structure** by reviewing the CIS Benchmark for your target distribution (Debian/Ubuntu). Understand the control categories: initial setup (filesystem, updates, boot), services (inetd, special purpose, service clients), network configuration (network parameters, firewall, wireless), logging and auditing (configure logging, ensure auditing), access/authentication (cron, SSH, PAM, user accounts), and system maintenance (file permissions, user settings).

2. **Build the audit framework** as a modular Bash script with a consistent check pattern: each control is a function that tests a specific configuration, returns pass/fail/warn/skip with evidence, and logs the result. Implement color-coded terminal output, a scoring engine that tracks compliance percentage, and structured output (JSON) for programmatic consumption.

3. **Implement filesystem and boot checks** verifying: separate partitions for /tmp, /var, /var/log with noexec/nosuid mount options, sticky bit on world-writable directories, disabled automounting, GPG-verified package repositories, AIDE or similar file integrity monitoring configured, and bootloader password protection.

4. **Add service and network auditing** checking: unnecessary services disabled (avahi, cups, DHCP, LDAP, NFS, DNS, FTP, HTTP, IMAP, Samba, squid, SNMP, rsync), network parameters hardened (IP forwarding disabled, ICMP redirects rejected, suspicious packet logging, TCP SYN cookies, IPv6 router advertisements), and firewall (iptables/nftables) rules ensuring default deny policy.

5. **Implement access control and authentication checks** for: cron job permissions, SSH hardening (Protocol 2, MaxAuthTries, PermitRootLogin, PermitEmptyPasswords, X11Forwarding, AllowUsers/Groups, cipher suites, MACs, key exchange algorithms), PAM configuration (password quality, failed login lockout, password reuse), password policy (maxdays, mindays, warndays, inactive), and root account restrictions.

6. **Build logging and audit checks** verifying: rsyslog or journald configured with appropriate retention, auditd installed and running with rules for privileged commands, file access monitoring, user/group changes, and system administration actions. Check log file permissions prevent unauthorized access.

7. **Create the compliance report generator** that produces a summary showing overall compliance score (percentage), score per category, individual control results with evidence, remediation commands for failed controls, and comparison against previous audit runs (if a baseline exists). Output formats: terminal (colored), JSON, and HTML.

8. **Write documentation** explaining CIS benchmark levels (Level 1 vs Level 2), how to interpret results, remediation priorities, and how to establish a baseline and track compliance over time. Include guidance on which controls may need exceptions in specific environments and how to document those exceptions.

## Key Concepts to Learn
- CIS benchmark framework and control categories
- Linux system hardening best practices
- SSH, PAM, and authentication security
- Firewall configuration and network hardening
- Audit logging and monitoring
- Advanced Bash scripting patterns
- Compliance reporting and scoring

## Deliverables
- Modular Bash audit framework
- 100+ CIS benchmark control checks
- Filesystem, network, service, and access auditing
- Scored compliance report (terminal, JSON, HTML)
- Remediation command suggestions
- Baseline comparison capability
