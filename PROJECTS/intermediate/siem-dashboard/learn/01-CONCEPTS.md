# Core Security Concepts

This document explains the security concepts you'll encounter while building this SIEM dashboard. These aren't just definitions. We'll dig into why they matter, how attacks actually work, and how this project implements defenses.

## Log Normalization

### What It Is

Different security tools produce logs in completely different formats. A firewall log has fields like `action`, `protocol`, and `bytes_sent`. An IDS log has `signature_id`, `classification`, and `priority`. An authentication log has `auth_method`, `result`, and `failure_reason`. Raw, these logs are incomparable.

Log normalization transforms all these different formats into a common schema so you can query, correlate, and analyze them together. In this project, the normalizer (`app/engine/normalizer.py`) takes raw events from seven source types and maps them into a unified `LogEvent` document with consistent fields like `source_ip`, `dest_ip`, `severity`, `event_type`, and a `normalized` dict for source-specific extras.

### Why It Matters

Without normalization, a SOC analyst investigating a suspicious IP would need to manually search each tool's interface separately. With normalized data, a single pivot query returns every firewall connection, every auth attempt, every DNS query, and every endpoint process execution from that IP.

The 2013 Target breach is a textbook case. Their FireEye IDS generated alerts about malware beaconing, but the team couldn't correlate those alerts with the POS system logs showing data exfiltration. The tools existed in silos. A functioning SIEM with proper normalization would have connected those dots.

### How It Works

The normalizer uses a registry pattern. Each source type registers a normalizer function via a decorator:

```
Source Type     Normalizer Function         Extracted Fields
─────────────  ─────────────────────────   ──────────────────────────
firewall       _normalize_firewall()       action, protocol, bytes_sent/received
ids            _normalize_ids()            signature_id, signature_name, priority
auth           _normalize_auth()           auth_method, result, failure_reason
endpoint       _normalize_endpoint()       process_name, command_line, file_path
dns            _normalize_dns()            query, query_type, response_code
proxy          _normalize_proxy()          url, method, status_code, user_agent
generic        _normalize_generic()        message (fallback)
```

The dispatch is straightforward. `normalize()` extracts common fields (IP addresses, ports, timestamps, hostnames), then calls the source-specific normalizer to extract fields unique to that log type. Both get merged into a single document.

### Common Pitfalls

**Mistake 1: Assuming all sources have the same fields**
```python
# Bad - will throw KeyError on auth logs
def process_event(event):
    bytes = event["bytes_sent"]  # Only firewall events have this

# Good - use .get() with defaults and check source_type
def process_event(event):
    if event.get("source_type") == "firewall":
        bytes = event.get("bytes_sent", 0)
```

**Mistake 2: Losing the raw data**

The normalizer in this project preserves the original event in the `raw` DictField on `LogEvent`. This is critical for forensics. Normalization is lossy by definition, and during an investigation you'll often need the original log line.

## Event Correlation

### What It Is

Correlation is the process of connecting multiple individual events into a higher level detection. A single failed login is noise. Twenty failed logins from the same IP in 60 seconds is a brute force attack. A brute force followed by a successful login is a compromise.

This project implements three correlation strategies in `app/engine/correlation.py`:

**Threshold** rules fire when the count of matching events for a group key exceeds a limit within a time window. Example: more than 10 `login_failure` events from the same `source_ip` in 300 seconds.

**Sequence** rules fire when a specific ordered set of event types occurs within a window. Example: `login_failure` (count >= 5) followed by `login_success` from the same `source_ip`.

**Aggregation** rules fire when the number of distinct values of a field exceeds a threshold. Example: one `source_ip` connects to more than 20 distinct `dest_ip` values in 60 seconds (port scan behavior).

### Why It Matters

Without correlation, a SIEM is just a log search engine. Correlation is what turns data into detections. The difference between a SIEM that generates useful alerts and one that drowns analysts in noise comes down to the quality of its correlation rules.

The 2020 SolarWinds attack went undetected for months partly because existing detection tools were looking at individual events in isolation. The attackers used valid credentials, standard protocols, and legitimate tools. Only correlating multiple weak signals across time (unusual service account behavior + new federation trust + anomalous DNS queries) could have surfaced the intrusion earlier.

### How It Works

The correlation engine runs as a daemon thread that consumes events from a Redis Stream:

```
Redis Stream (siem:logs)
        │
        ▼
┌───────────────────┐
│ CorrelationEngine │  Daemon thread, reads via XREADGROUP
│   ._run() loop    │
└────────┬──────────┘
         │
         ▼
┌───────────────────┐
│  _process_event() │  Iterates all enabled rules
└────────┬──────────┘
         │
    ┌────┴────┬──────────┐
    ▼         ▼          ▼
Threshold  Sequence  Aggregation
evaluator  evaluator  evaluator
    │         │          │
    └────┬────┘──────────┘
         │
    Fire? ──Yes──▶ Alert.create_from_rule()
                         │
                         ▼
                  Redis Stream (siem:alerts)
                         │
                         ▼
                   SSE to browser
```

Each evaluator uses a `CorrelationState` object that maintains sliding windows in memory. The state is thread-safe (uses `threading.Lock`) and tracks per-rule, per-group-key windows of events. When evaluating, it prunes expired entries based on `window_seconds` and checks whether the firing condition is met.

A cooldown mechanism (`CORRELATION_COOLDOWN_SECONDS`, default 300) prevents the same rule from firing repeatedly for the same group key. Without this, a sustained brute force would generate hundreds of identical alerts.

### Common Attacks This Detects

1. **Brute Force (T1110.001)** - Threshold rule: count `login_failure` events grouped by `source_ip`, fire when count > 10 in 300 seconds
2. **Lateral Movement (T1021.004)** - Sequence rule: `login_success` from external IP followed by internal SSH connections from the compromised host
3. **Port Scanning (T1046)** - Aggregation rule: count distinct `dest_ip` values per `source_ip`, fire when > 20 unique destinations in 60 seconds
4. **DNS Tunneling (T1048.003)** - Threshold rule on high-frequency TXT queries to a single domain, or aggregation on distinct query subdomains

### Defense Strategies

The correlation engine itself is a defense mechanism. But it needs well-tuned rules. This project ships with scenario playbooks that demonstrate attacks and the rules that detect them. The `brute_force_lateral.yml` playbook, for example, simulates 20 SSH login failures followed by a successful login and lateral movement. A threshold rule on `login_failure` grouped by `source_ip` with threshold 10 and window 300 would catch the brute force phase.

## Severity Classification

### What It Is

Not all security events are equally urgent. A firewall allowing an outbound HTTPS connection is informational. A process executing `cat /etc/shadow` is high severity. Severity classification assigns a priority level to each event so analysts focus on what matters.

This project classifies events into five levels: `critical`, `high`, `medium`, `low`, and `info`. The classifier in `app/engine/severity.py` uses two approaches: event type lookup (fast, for known event types) and regex pattern matching (flexible, for content-based classification).

### How It Works

The classifier checks event types first against frozen sets:

```
HIGH_SEVERITY_EVENT_TYPES:  privilege_escalation, data_exfiltration,
                            c2_communication, reverse_shell

MEDIUM_SEVERITY_EVENT_TYPES: login_failure, port_scan,
                             firewall_deny, ids_alert
```

If the event type doesn't match, it falls through to regex matching. The classifier concatenates relevant text fields (event_type, message, normalized fields like signature_name and command_line) into a searchable string, then runs regex patterns from critical down to low. First match wins.

Critical patterns include things like `privilege.?escalat`, `ransomware`, and `c2.?beacon`. High patterns include `brute.?force`, `lateral.?movement`, and `reverse.?shell`. The regex uses `re.IGNORECASE` for case insensitive matching and `?` for optional separators (so "privilege escalation" and "privilege_escalation" both match).

### Common Pitfalls

**Mistake: Classifying everything as high severity**

This leads to alert fatigue. If everything is critical, nothing is. The classifier in this project defaults to `info` for events that don't match any pattern. This is intentional. An unknown event type with no suspicious keywords is probably routine. Better to miss a low-confidence detection than to bury real alerts in noise.

## Authentication and Authorization Security

### What It Is

The SIEM itself needs to be secured. If an attacker compromises the SIEM, they can suppress alerts, manipulate rules, and cover their tracks. This project implements JWT-based authentication with Argon2id password hashing and role-based access control.

### How It Works

The auth system in `app/core/auth.py` uses `pwdlib` with Argon2id, the winner of the 2015 Password Hashing Competition. Argon2id is memory-hard, meaning it's resistant to GPU-based cracking attacks that make bcrypt and SHA-based hashes vulnerable.

A critical detail: the `verify_password_timing_safe()` function provides constant-time behavior for failed lookups. When a login attempt uses a username that doesn't exist, the system still performs a hash comparison against a dummy hash (`DUMMY_HASH`). This prevents timing attacks that could enumerate valid usernames by measuring response time differences.

```
Login attempt with valid username:
  1. Look up user → found
  2. Verify password against stored hash → ~150ms (Argon2id)
  3. Return result

Login attempt with invalid username:
  1. Look up user → not found
  2. Verify password against DUMMY_HASH → ~150ms (same timing)
  3. Return "Invalid username or password"
```

Without this, an attacker could distinguish "user doesn't exist" (fast response) from "wrong password" (slow response, because Argon2id is intentionally expensive).

### RBAC Model

Two roles: `analyst` (default) and `admin`. The `@endpoint(roles=ADMIN)` decorator on admin routes checks the JWT claims. Admins can manage users, change roles, and deactivate accounts. The system protects against demoting the last admin (`User.count_admins()` check in `admin_ctrl.py`).

## Real-Time Event Streaming

### What It Is

A SIEM that only shows data on page refresh is nearly useless during an active incident. Analysts need to see events as they happen. This project uses Redis Streams for internal event delivery and Server-Sent Events (SSE) for browser updates.

### How It Works

When a log event is ingested or an alert is created, it's published to a Redis Stream via `XADD`. The correlation engine reads from the log stream using `XREADGROUP` with consumer groups (reliable delivery with acknowledgment). The SSE endpoints use `XREAD` to tail the stream and emit events to connected browsers.

```
Log Ingestion ──XADD──▶ Redis Stream (siem:logs)
                              │
              ┌───────────────┼───────────────┐
              │               │               │
         XREADGROUP      XREADGROUP        XREAD
              │               │               │
     Correlation         (Future          SSE Generator
       Engine           consumers)       ──▶ Browser
              │
         Alert Created ──XADD──▶ Redis Stream (siem:alerts)
                                       │
                                    XREAD
                                       │
                                  SSE Generator
                                  ──▶ Browser
```

The SSE generator in `app/core/streaming.py` sends keepalive comments (`: keepalive\n\n`) when no events arrive within the block timeout. This prevents proxy timeouts and lets the browser detect dropped connections. The Nginx config disables buffering and sets `proxy_read_timeout 3600s` for SSE endpoints.

## How These Concepts Relate

```
Raw Log Event
    │
    ▼
Normalization (common schema)
    │
    ▼
Severity Classification (priority label)
    │
    ▼
Persistence (MongoDB) + Publish (Redis Stream)
    │
    ├──▶ SSE to browser (real-time log viewer)
    │
    ▼
Correlation Engine (pattern matching across events)
    │
    ▼
Alert Generation
    │
    ├──▶ SSE to browser (real-time alert feed)
    │
    ▼
Alert Lifecycle (new → acknowledged → investigating → resolved)
    │
    ▼
Forensic Investigation (pivot queries, matched event drill-down)
```

Each concept builds on the previous one. Without normalization, correlation can't compare events across sources. Without severity classification, analysts can't prioritize. Without streaming, response time suffers. Without correlation, individual events are meaningless noise.

## Industry Standards and Frameworks

### OWASP

While OWASP focuses on application security, several categories apply to the SIEM itself:
- **A01:2021 Broken Access Control** - The RBAC system with `@endpoint(roles=ADMIN)` prevents unauthorized access to admin functions. The `_prevent_self_action()` helper blocks admins from deactivating their own accounts.
- **A02:2021 Cryptographic Failures** - Argon2id for password hashing, HS256 JWTs with configurable expiration. The `SECRET_KEY` default of "change-me-in-production" is intentionally obvious.
- **A07:2021 Identification and Authentication Failures** - Timing-safe password verification, rate limiting on auth endpoints (10/minute), account deactivation support.

### MITRE ATT&CK

The scenario playbooks map directly to MITRE techniques:

- **T1110.001 (Brute Force: Password Guessing)** - `brute_force_lateral.yml` simulates 20 SSH password attempts across common usernames
- **T1021.004 (Remote Services: SSH)** - Lateral movement via SSH key reuse after initial compromise
- **T1048.003 (Exfiltration Over Alternative Protocol: DNS)** - `data_exfiltration.yml` simulates DNS tunneling with high-entropy TXT queries
- **T1059.001 (Command and Scripting Interpreter: PowerShell)** - `phishing_c2.yml` includes encoded PowerShell download cradle execution
- **T1068 (Exploitation for Privilege Escalation)** - `privilege_escalation.yml` simulates kernel exploit compilation and execution
- **T1071.001 (Application Layer Protocol: Web)** - C2 beaconing over HTTPS with regular intervals

Correlation rules store `mitre_tactic` and `mitre_technique` fields, and these propagate to generated alerts for analyst context.

### CWE

Common weakness enumerations relevant to what this project teaches:
- **CWE-778 (Insufficient Logging)** - The entire project is about solving this. Seven source types with format-specific normalization.
- **CWE-223 (Omission of Security-Relevant Information)** - The normalizer preserves raw event data alongside normalized fields.
- **CWE-779 (Logging of Excessive Data)** - Redis Streams use `maxlen` with approximate trimming (`STREAM_MAXLEN = 10000`) to prevent unbounded growth.
- **CWE-307 (Improper Restriction of Excessive Authentication Attempts)** - Rate limiting on auth endpoints plus correlation rules for brute force detection.

## Real World Examples

### Case Study 1: Target Corporation Breach (2013)

Target's network was breached via a phishing email sent to an HVAC vendor. The attackers moved laterally to POS systems and installed RAM-scraping malware. Target's FireEye IDS detected the malware and generated alerts, but the SOC team failed to correlate those alerts with the broader attack chain.

This is exactly the kind of failure a SIEM with proper correlation prevents. A sequence rule looking for "external access → credential theft → lateral movement → data access" would have connected the dots. The scenario playbook `brute_force_lateral.yml` in this project simulates a similar kill chain: external brute force → credential harvest → SSH lateral movement → database dump.

### Case Study 2: DNS Tunneling in the APT34/OilRig Campaign

APT34 (also known as OilRig) used DNS tunneling to exfiltrate data from compromised networks. They encoded stolen data in DNS query subdomains, sending it to attacker-controlled nameservers. The technique works because most firewalls allow outbound DNS traffic without deep inspection.

The `data_exfiltration.yml` playbook simulates this exact technique. It generates high-entropy TXT queries to subdomains like `4d5a90000300000004000000ffff0000b800.data.exfil-tunnel.tk`. A threshold correlation rule on DNS query frequency, or an aggregation rule on distinct subdomains per destination domain, would detect this activity.

### Case Study 3: Emotet/TrickBot Delivery Chain

TA542's campaigns follow a consistent pattern: spear-phishing email → macro-enabled document → PowerShell download cradle → second-stage payload → C2 beaconing. The `phishing_c2.yml` playbook reproduces this chain event by event, from the initial proxy log of the phishing link click through to periodic C2 beacon heartbeats.

This demonstrates why sequence correlation matters. Any individual event in the chain could be benign. Downloading an Excel file is normal. Running PowerShell is normal. Outbound HTTPS is normal. But the sequence of Excel → cmd.exe → PowerShell → download → C2 beaconing is not normal, and a sequence rule can catch it.

## Testing Your Understanding

Before moving to the architecture, make sure you can answer:

1. Why does the normalizer preserve the raw event data in addition to normalized fields? What investigation scenario would require the raw data?
2. What's the difference between a threshold rule and an aggregation rule? Give an example attack that each would detect but the other wouldn't.
3. Why does `verify_password_timing_safe()` hash against a dummy value when the user doesn't exist? What information leak does this prevent?
4. If the correlation engine's cooldown is set to 300 seconds, what happens during a sustained 10-minute brute force? How many alerts would fire?
5. Why does the SSE generator send keepalive comments? What would happen in a production deployment behind Nginx without them?

If these questions feel unclear, re-read the relevant sections. The implementation details will make more sense once these fundamentals click.

## Further Reading

**Essential:**
- [MITRE ATT&CK Framework](https://attack.mitre.org/) - The taxonomy this project's scenarios and rules are built around. Start with the "Enterprise" matrix.
- [Redis Streams documentation](https://redis.io/docs/data-types/streams/) - Understanding XADD, XREADGROUP, consumer groups, and acknowledgment is critical for understanding the streaming layer.

**Deep dives:**
- [Sigma Rules](https://github.com/SigmaHQ/sigma) - An open standard for SIEM detection rules. Challenge 6 in the challenges doc suggests implementing Sigma rule support.
- [OWASP Password Storage Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html) - Why Argon2id was chosen over bcrypt, and the recommended parameter tuning.

**Historical context:**
- Mandiant's APT1 Report (2013) - One of the first public threat intelligence reports, and a great example of the kind of investigation workflow a SIEM enables.
- NIST SP 800-92 (Guide to Computer Security Log Management) - The foundational document on why and how to collect, store, and analyze security logs.
