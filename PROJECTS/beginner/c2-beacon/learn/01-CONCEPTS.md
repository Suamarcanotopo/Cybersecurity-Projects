<!-- © AngelaMos | 2026 | 01-CONCEPTS.md -->

# C2 Beacon Concepts

This document covers the core ideas behind Command and Control (C2) infrastructure, how our project implements them, and how they map to real-world offensive and defensive security. Read time is roughly 15-20 minutes. By the end you should understand why C2 works the way it does, what each command in our beacon does from a MITRE ATT&CK perspective, and how defenders catch exactly this kind of traffic.

---

## Command and Control (C2) Architecture

### What It Is

Picture this scenario. An attacker has already gotten into a corporate network, maybe through a phishing email, maybe through an unpatched VPN appliance. They have code running on a target machine. Now what? They need a way to tell that code what to do, and they need to get results back.

That is what C2 solves. Command and Control is the communication channel between an attacker and compromised systems. The attacker runs a **server** (sometimes called a team server or listener) on infrastructure they control. The compromised machine runs an **implant** (also called a beacon, agent, or payload) that reaches out to that server, asks for instructions, executes them, and sends results back.

In concrete terms:

1. The attacker compromises a machine and deploys a beacon binary or script.
2. The beacon initiates an outbound connection to the C2 server.
3. The server queues commands for the beacon (run this shell command, grab that file, take a screenshot).
4. The beacon picks up queued commands, executes them locally, and sends results back over the same channel.
5. The operator sees results in a dashboard or terminal.

This phase of an intrusion, the C2 phase, is one of the most critical. Without it, an attacker has a one-shot exploit. With it, they have persistent, interactive access to the target. The Lockheed Martin Cyber Kill Chain places C2 as step 6 of 7. MITRE ATT&CK dedicates an entire tactic category to it (TA0011). Every major breach you have read about, from SolarWinds (SUNBURST) to the Colonial Pipeline ransomware incident, involved sustained C2 communications.

### The Beacon/Server Model

A natural question: why does the beacon call out to the server? Why not have the server connect inbound to the target?

The answer is firewalls and NAT. Corporate networks almost universally block unsolicited inbound connections. Workstations sit behind NAT gateways without public IP addresses. A server trying to connect to port 4444 on an internal workstation would be dropped at the perimeter immediately.

But outbound traffic? That flows freely in most environments. Employees browse the web, call APIs, stream video. A beacon making HTTPS requests to what looks like a legitimate domain blends right into that traffic. From the firewall's perspective, the beacon's outbound WebSocket connection looks similar to any other web application traffic.

Cobalt Strike, the most widely used commercial red team C2 framework, popularized this model with its "beacon" concept. A Cobalt Strike beacon sleeps for a configured interval (default 60 seconds), wakes up, contacts the team server over HTTP/HTTPS, downloads any queued commands, executes them, and posts results back. The name "beacon" comes from this periodic check-in pattern, like a lighthouse blinking at regular intervals.

Our project follows this same model. The beacon (`beacon/beacon.py`) initiates a WebSocket connection to the server (`backend/app/beacon/router.py`). The server never tries to reach the beacon. The beacon always calls home.

### Why Attackers Use C2

Five core reasons:

**Persistent access after initial compromise.** The initial exploit might be a one-time event, a phishing link clicked, a vulnerability triggered. C2 gives the attacker a durable channel that survives the initial vector being patched or discovered. Combined with persistence mechanisms (cron jobs, registry keys, scheduled tasks), the beacon comes back even after reboots.

**Command execution without interactive sessions.** An attacker does not need to maintain an open SSH or RDP session. The beacon operates asynchronously. The operator queues a command, walks away, and checks results hours later. This is especially useful in long-duration operations where constant interaction would be suspicious.

**Exfiltration of data through the C2 channel.** Stolen data leaves the network through the same encrypted channel the commands arrive on. No separate FTP server, no suspicious cloud uploads. The data rides out inside the C2 protocol, often chunked and encoded to avoid detection.

**Lateral movement coordination.** Once inside a network, attackers pivot from machine to machine. A single C2 server can manage dozens or hundreds of beacons across a compromised environment, coordinating actions like credential harvesting on one machine, lateral movement to another, and data staging on a third.

**Maintaining stealth through encrypted channels.** C2 traffic is typically encrypted (TLS, mTLS, or custom encryption). Even if a defender captures the packets, they see encrypted blobs. Combine this with domain fronting or legitimate cloud infrastructure and the traffic becomes very difficult to distinguish from normal business operations.

### Real World C2 Frameworks

Here is how our project sits alongside the frameworks used in actual operations:

| Framework | Language | Protocol | Notable Use |
|-----------|----------|----------|-------------|
| Cobalt Strike | Java | HTTP/HTTPS/DNS | Most common in APT campaigns. Used by both red teams and threat actors like APT29, FIN7, and Conti ransomware operators. |
| Sliver | Go | mTLS/HTTP/DNS/WireGuard | Open source alternative to Cobalt Strike. Gained adoption after Cobalt Strike cracks became heavily signatured. |
| Mythic | Python/Go | HTTP/WebSocket | Modular framework with community-contributed agents. Each agent is its own project with its own capabilities. |
| Brute Ratel | C++ | HTTP/DNS | Designed specifically to evade EDR products. Gained attention in 2022 when cracked copies appeared in the wild. |
| Our Project | Python | WebSocket | Educational. Demonstrates the architecture pattern without operational security features. |

The important thing to notice: every one of these frameworks implements the same core pattern. Server listens, beacon calls home, commands flow down, results flow up. The differences are in protocol sophistication, evasion capabilities, and operational security. Our project strips away the evasion complexity so you can focus on understanding the architecture itself.

---

## MITRE ATT&CK Mapping

### What Is MITRE ATT&CK?

MITRE ATT&CK is a knowledge base of adversary tactics and techniques based on real-world observations. Think of it as a taxonomy of everything attackers do, organized into categories like Initial Access, Execution, Persistence, Discovery, Collection, Exfiltration, and Command and Control.

Every technique gets an ID (like T1059 for Command and Scripting Interpreter). Security teams use these IDs to classify incidents, measure detection coverage, and communicate about threats in a shared language. When a SOC analyst writes "we observed T1059.001 execution," every other analyst knows they mean PowerShell was used to run commands.

The framework lives at [https://attack.mitre.org/](https://attack.mitre.org/) and is updated regularly as new techniques are observed in the wild.

Our beacon implements 10 commands. Each one maps to a specific ATT&CK technique. Here is the full mapping:

### Command-to-Technique Table

| Command | Technique ID | Tactic | Technique Name |
|---------|-------------|--------|----------------|
| `shell` | T1059 | Execution | Command and Scripting Interpreter |
| `sysinfo` | T1082 | Discovery | System Information Discovery |
| `proclist` | T1057 | Discovery | Process Discovery |
| `upload` | T1105 | Command and Control | Ingress Tool Transfer |
| `download` | T1041 | Exfiltration | Exfiltration Over C2 Channel |
| `screenshot` | T1113 | Collection | Screen Capture |
| `keylog_start` | T1056.001 | Collection | Input Capture: Keylogging |
| `keylog_stop` | T1056.001 | Collection | Input Capture: Keylogging |
| `persist` | T1053.003 | Persistence | Scheduled Task/Job: Cron |
| `sleep` | T1029 | Command and Control | Scheduled Transfer |

### Detailed Breakdown

**shell (T1059 - Command and Scripting Interpreter)**

This is the most fundamental C2 capability. The beacon receives a string, passes it to `asyncio.create_subprocess_shell()`, captures stdout and stderr, and sends both back. In our codebase, `handle_shell` in `beacon/beacon.py` does exactly this. In real attacks, T1059 is present in nearly every intrusion. The SolarWinds SUNBURST implant used `cmd.exe` for command execution. The technique has sub-techniques for specific interpreters: T1059.001 (PowerShell), T1059.003 (Windows Command Shell), T1059.004 (Unix Shell). Our beacon uses the system default shell on whatever OS it runs on.

**sysinfo (T1082 - System Information Discovery)**

After landing on a machine, attackers need to understand what they are working with. Our `handle_sysinfo` collects hostname, OS version, architecture, CPU count, memory totals, disk partitions, and network interfaces using the `psutil` library. This is reconnaissance. APT groups routinely run `systeminfo`, `uname -a`, or equivalent commands as one of their first actions. During the 2020 SolarWinds campaign, SUNBURST collected OS version, domain name, and installed security products before the operators decided whether a target was worth pursuing.

**proclist (T1057 - Process Discovery)**

Enumerating running processes tells an attacker several things: what security tools are running (is there an EDR agent? an antivirus?), what user context processes run under, and what services are active. Our `handle_proclist` iterates `psutil.process_iter()` and returns PIDs, names, and usernames for up to 100 processes. In real operations, process listings help attackers decide which processes to inject into, which security tools to evade, and which services to target for credential theft.

**upload (T1105 - Ingress Tool Transfer)**

Uploading files to a compromised host is how attackers stage additional tools. Our `handle_upload` receives a JSON object containing a filename and base64-encoded content, then writes it to `/tmp/`. In the real world, attackers upload privilege escalation exploits, lateral movement tools like Mimikatz, additional implants, or tunnel utilities. The T1105 technique is present whenever you see an attacker pushing a binary to a compromised system through the C2 channel rather than having the target download it from the internet.

**download (T1041 - Exfiltration Over C2 Channel)**

This is the data theft capability. Our `handle_download` reads a file from disk, base64-encodes it, and sends it back through the WebSocket. The key detail here: the stolen data exits through the same channel the commands arrive on. Defenders looking for exfiltration via unusual protocols or cloud storage uploads would miss this because the data is embedded in C2 traffic. The DarkSide ransomware group (responsible for the Colonial Pipeline attack) used their C2 channel to exfiltrate gigabytes of corporate data before deploying the ransomware payload.

**screenshot (T1113 - Screen Capture)**

Taking screenshots lets attackers see what a user is doing in real time. Our `handle_screenshot` uses the `mss` library to grab the full screen, converts it to PNG, and base64-encodes the result. This technique is common in espionage operations. APT28 (Fancy Bear) used screenshot capabilities in their X-Agent implant to monitor targets. It is also used in financial crime to capture banking sessions and credential entry.

**keylog_start / keylog_stop (T1056.001 - Input Capture: Keylogging)**

Keylogging captures everything a user types: passwords, messages, search queries, internal URLs. Our beacon uses `pynput` to hook keyboard events in a background thread. `handle_keylog_start` begins capture, `handle_keylog_stop` terminates the listener and returns all captured keystrokes. Keyloggers are among the oldest offensive tools. The difference between a standalone keylogger and what we have here is that ours is integrated into the C2 framework, so captured keystrokes are exfiltrated automatically through the beacon's existing channel rather than requiring a separate retrieval mechanism.

**persist (T1053.003 - Scheduled Task/Job: Cron)**

Persistence is how an attacker survives reboots. Without it, the beacon dies when the machine restarts and the attacker loses access. Our `handle_persist` writes a `@reboot` cron entry that re-launches the beacon on system startup. The function checks the current crontab, verifies the entry does not already exist, and appends it. This is a Linux-specific technique. The technique ID T1053.003 specifically covers cron-based persistence. In real operations, APT groups like TeamTNT have used cron persistence extensively in their cryptocurrency mining campaigns targeting Linux servers.

**sleep (T1029 - Scheduled Transfer)**

Adjusting the sleep interval is an operational security control. Our `handle_sleep` lets the operator modify `sleep_interval` and `jitter_percent` on the fly. During an initial compromise, an attacker might use a short sleep (1-5 seconds) for rapid interaction. Once they have established access and want to avoid detection, they increase it to minutes or hours. Cobalt Strike operators routinely set sleep intervals to 300-900 seconds with 30-50% jitter during long-term operations. The T1029 mapping reflects that the beacon transfers data on a schedule rather than in real time, which is a defining characteristic of C2 beaconing.

---

## Protocol Encoding

### XOR Cipher

XOR (exclusive or) is the simplest reversible binary operation. Given two bits, XOR returns 1 if they differ and 0 if they match:

```
0 XOR 0 = 0
0 XOR 1 = 1
1 XOR 0 = 1
1 XOR 1 = 0
```

The property that makes XOR useful for encoding: applying the same key twice returns the original data.

```
data XOR key = encoded
encoded XOR key = data
```

Here is the concrete math with a single byte. Say the data byte is `0x48` (the letter "H") and the key byte is `0x63` (the letter "c"):

```
0x48 = 01001000
0x63 = 01100011
XOR  = 00101011 = 0x2B
```

Apply the key again:

```
0x2B = 00101011
0x63 = 01100011
XOR  = 01001000 = 0x48 = "H"
```

Our project implements this in `backend/app/core/encoding.py`:

```python
def xor_bytes(data: bytes, key: bytes) -> bytes:
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))
```

The `i % len(key)` part is critical. It makes the key repeat. If the key is "abc" (3 bytes) and the data is 10 bytes long, the key cycles: a,b,c,a,b,c,a,b,c,a. Each data byte gets XORed with the corresponding key byte at that position.

**Why XOR alone is weak.** Two major problems:

First, **known plaintext attacks**. If an attacker knows (or can guess) any part of the plaintext, they can recover the key. Since our protocol sends JSON messages that always start with `{"type":`, an attacker who captures the encoded output can XOR the known plaintext against the ciphertext to extract the key. Once they have the key, they can decode everything.

Second, **frequency analysis**. With a short, repeating key, statistical patterns in the plaintext leak through. The letter "e" appears roughly 13% of the time in English text. If the key repeats every 32 bytes, you can split the ciphertext into 32 streams and do frequency analysis on each one independently. This is the classic Vigenere cipher weakness, and XOR with a repeating key is essentially Vigenere operating on bits instead of letters.

### Why XOR + Base64

Our encoding pipeline uses both XOR and Base64 for different reasons:

- **XOR provides basic obfuscation.** It is not real encryption. It will not stop a determined analyst. But it means the protocol messages are not sitting on the wire as readable JSON. A casual observer or basic string-matching IDS rule will not immediately see `{"type":"TASK","payload":{"command":"shell"}}` in the traffic.

- **Base64 makes binary safe for text transport.** After XOR, the data is arbitrary bytes, including null bytes and other values that break text protocols. Base64 converts those bytes into a safe ASCII alphabet (A-Z, a-z, 0-9, +, /). This matters because WebSocket text frames expect valid text data. Without Base64, we would need to use binary WebSocket frames, which is a valid approach but adds complexity we do not need in a beginner project.

- **Real C2 frameworks use actual encryption.** Cobalt Strike uses AES-256 in CBC mode. Sliver uses mutual TLS (mTLS) where both the server and beacon authenticate with certificates. Brute Ratel uses a combination of RC4 and AES. We use XOR because the goal of this project is to teach the architectural pattern, not to build something operationally secure. Understanding XOR encoding helps you understand what real encryption is doing at a conceptual level without the complexity of key exchange, initialization vectors, and cipher modes.

### The Encoding Pipeline

Here is the full path a message takes from plaintext to wire format and back:

**Encoding (beacon to server, or server to beacon):**

```
Plaintext JSON --> UTF-8 bytes --> XOR with key --> Base64 --> WebSocket text frame
```

Step by step with a real example. Say the message is `{"type":"HEARTBEAT","payload":{"id":"abc-123"}}` and the key is `c2-beacon-default-key-change-me`:

1. The JSON string becomes UTF-8 bytes: `7b 22 74 79 70 65 ...`
2. Each byte gets XORed with the repeating key bytes: `7b^63, 22^32, 74^2d, 79^62, ...`
3. The resulting binary blob gets Base64 encoded into a printable ASCII string.
4. That string is sent as a WebSocket text frame.

**Decoding (receiving side):**

```
WebSocket text frame --> Base64 decode --> XOR with key --> UTF-8 string --> JSON parse
```

You can see both directions implemented in `backend/app/core/encoding.py`:

```python
def encode(payload: str, key: str) -> str:
    raw = payload.encode("utf-8")
    xored = xor_bytes(raw, key.encode("utf-8"))
    return base64.b64encode(xored).decode("ascii")


def decode(encoded: str, key: str) -> str:
    xored = base64.b64decode(encoded)
    raw = xor_bytes(xored, key.encode("utf-8"))
    return raw.decode("utf-8")
```

The protocol layer (`backend/app/core/protocol.py`) wraps these functions with Pydantic validation. The `pack` function serializes a `Message` object to JSON, then encodes it. The `unpack` function decodes, parses, and validates in one step. If any step fails (bad Base64, XOR produces invalid UTF-8, JSON is malformed, Pydantic validation fails), `unpack` raises a `ValueError`.

---

## Beacon Behavior Patterns

### Sleep and Jitter

A beacon that calls home every second, on the second, is trivially detectable. Network monitoring tools can identify periodic connections with high confidence. If a host makes an HTTPS request to the same domain at exactly 1-second intervals for hours on end, that is a massive red flag.

Sleep intervals solve part of this problem. Instead of constant communication, the beacon waits between check-ins. Our project defaults to a 3-second sleep interval, which is aggressive for a real operation but good for interactive demos.

Jitter solves the rest. Jitter adds randomness to the sleep interval. Our beacon uses 30% jitter by default:

```python
def jittered_sleep() -> float:
    jitter = config.sleep_interval * config.jitter_percent
    return config.sleep_interval + random.uniform(-jitter, jitter)
```

With a 3-second interval and 30% jitter, the actual sleep time ranges from 2.1 seconds to 3.9 seconds. Each cycle is different. The timing pattern looks irregular rather than metronome-like.

For reference, Cobalt Strike defaults to a 60-second sleep interval with 0% jitter. That 0% default is considered poor operational security, and experienced operators immediately change it. Common real-world settings are 300 seconds (5 minutes) with 30-50% jitter for long-term operations. During active engagement where the operator needs quick responses, they might use 5-10 seconds with 10-20% jitter.

The trade-off is responsiveness versus stealth. A short sleep means the operator gets results quickly. A long sleep with high jitter makes the beacon harder to detect but means you might wait 10 minutes for a command to execute.

### Heartbeats

The server needs to know which beacons are still alive. If a beacon goes silent, is it because the host was shut down? Did the network path change? Was the beacon detected and killed by an EDR?

Our beacon sends periodic heartbeat messages during the sleep loop:

```python
async def heartbeat_loop(ws: Any) -> None:
    while True:
        try:
            msg = pack("HEARTBEAT", {"id": config.beacon_id})
            await ws.send(msg)
            await asyncio.sleep(jittered_sleep())
        except Exception:
            break
```

Each heartbeat updates the `last_seen` timestamp in the server's database (via `registry.update_last_seen` in `backend/app/beacon/registry.py`). The dashboard displays this timestamp so the operator can see at a glance which beacons are actively checking in versus which have gone dark.

In production C2 frameworks, the heartbeat is often implicit rather than explicit. The act of checking in for tasks serves as the heartbeat. Our project uses explicit heartbeat messages because WebSocket connections are persistent, and we need a mechanism to keep the connection alive and update timestamps even when no tasks are queued.

### Reconnection Strategy

Networks are unreliable. Servers restart. Firewalls reset connections. The beacon needs to handle all of this gracefully.

Our beacon implements exponential backoff:

```
Attempt 1: wait 2 seconds
Attempt 2: wait 4 seconds
Attempt 3: wait 8 seconds
Attempt 4: wait 16 seconds
...continuing to double...
Attempt N: wait up to 300 seconds (5-minute cap)
```

The relevant code in `beacon/beacon.py`:

```python
backoff = config.reconnect_base

while True:
    try:
        async with connect(config.server_url) as ws:
            backoff = config.reconnect_base
            ...
    except (ConnectionRefusedError, websockets.exceptions.ConnectionClosed, OSError):
        await asyncio.sleep(backoff)
        backoff = min(backoff * 2, config.reconnect_max)
```

Two things to notice. First, on a successful connection, `backoff` resets to the base value (2 seconds). Second, the backoff caps at `reconnect_max` (300 seconds). Without the cap, the backoff would grow indefinitely and the beacon could end up waiting hours between attempts.

Why exponential backoff matters: if the server is down and 50 beacons are trying to reconnect simultaneously, you do not want all 50 hammering the server every 2 seconds. That creates network noise and could look like a DDoS. Exponential backoff spreads out the reconnection attempts over time, reducing load and reducing visibility.

---

## Persistence Mechanisms

Persistence means the implant survives system reboots. Without persistence, the beacon dies when the machine restarts, and the attacker has to re-compromise the target from scratch. That is expensive and risky. Every compromise attempt is a chance to get caught.

Our project implements one persistence mechanism: cron-based persistence on Linux. The `handle_persist` function in `beacon/beacon.py` adds a `@reboot` cron entry that re-launches the beacon script when the system starts:

```python
beacon_path = os.path.abspath(__file__)
cron_entry = f"@reboot /usr/bin/python3 {beacon_path} &"
```

The function reads the current crontab, checks if the entry already exists (to avoid duplicates), and appends it if needed.

Cron persistence is straightforward and effective on Linux systems, but it is also straightforward to detect. Any defender who checks `crontab -l` will see it. More sophisticated attackers use harder-to-detect mechanisms.

Here are the common persistence techniques organized by operating system:

**Linux:**
- Cron jobs (what we use) - `@reboot` entries or scheduled entries
- Systemd services - a `.service` unit file in `/etc/systemd/system/`
- Bash profile modification - adding execution lines to `~/.bashrc` or `~/.profile`
- Init scripts - adding to `/etc/rc.local` or `/etc/init.d/`

**Windows:**
- Registry run keys - `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` or the HKLM equivalent
- Scheduled tasks - `schtasks.exe /create` with various triggers
- DLL hijacking - placing a malicious DLL in a directory searched before the legitimate one
- Windows services - registering as a system service
- WMI event subscriptions - triggering execution on WMI events

**macOS:**
- Launch agents - plist files in `~/Library/LaunchAgents/`
- Launch daemons - plist files in `/Library/LaunchDaemons/`
- Login items - using the Shared File List or Service Management framework
- Dylib hijacking - the macOS equivalent of DLL hijacking

Each of these maps to a different MITRE ATT&CK sub-technique under T1053 (Scheduled Task/Job), T1547 (Boot or Logon Autostart Execution), or T1574 (Hijack Execution Flow). The common thread: the attacker arranges for their code to run automatically when some trigger fires (boot, login, scheduled time, application launch).

---

## Detection and Defense

### How Blue Teams Detect C2

Understanding detection is just as important as understanding the attack. If you only know how to build C2, you are missing half the picture. Here is how defenders find and stop beacon traffic.

**Network Signatures and Traffic Analysis**

The most direct detection method. Network security monitoring (NSM) tools analyze traffic for patterns associated with C2:

- **Periodic beaconing patterns.** Even with jitter, statistical analysis can identify connections that occur at semi-regular intervals. Tools like RITA (Real Intelligence Threat Analytics) specialize in detecting beaconing by analyzing connection frequency distributions. If a host contacts the same external server 480 times in 24 hours at roughly 3-minute intervals, that is statistically identifiable.

- **Unusual WebSocket connections.** Most corporate workstations do not maintain long-lived WebSocket connections to external servers. A WebSocket connection that persists for hours and transmits small, regular messages is suspicious. Our project uses plain WebSocket (the `ws://` scheme), which means the traffic content is visible to any inline inspection device.

- **Encoded payload patterns.** Base64-encoded blobs in WebSocket frames are unusual for legitimate applications. While some applications use Base64 for binary data, a sustained pattern of Base64 messages with consistent sizes at regular intervals stands out.

- **JA3/JA3S fingerprinting.** JA3 creates a hash of the TLS Client Hello parameters (cipher suites, extensions, elliptic curves). JA3S does the same for the Server Hello. Known C2 frameworks produce distinctive JA3 fingerprints because they use specific TLS libraries with specific configurations. Cobalt Strike's default JA3 hash is well-documented and widely signatured. Our project does not use TLS in development, which makes this specific detection method inapplicable but also means our traffic is completely readable to anyone on the network.

- **DNS anomalies.** DNS-based C2 frameworks (like the DNS modes in Cobalt Strike, Sliver, and Brute Ratel) encode data in DNS queries and responses. Detectable signs include high volumes of TXT record queries, unusually long subdomain labels, and DNS traffic to domains with high entropy names. Our project does not use DNS for C2, but you should know about this technique.

**Behavioral Analysis on Endpoints**

Even if the network traffic is encrypted and blends in, the actions the beacon takes on the host are detectable:

- **Processes spawning shells.** When our beacon executes a `shell` command, it creates a child process running a shell command. A Python process spawning `/bin/sh` or `cmd.exe` is suspicious. EDR products track process parent-child relationships. If `python3` spawns `bash` which spawns `whoami`, that process tree gets flagged.

- **Unusual file access.** The `download` command reads files. The `upload` command writes to `/tmp/`. The `screenshot` command accesses screen capture APIs. EDR products monitor these operations and can flag anomalous patterns, especially when they originate from a process that does not normally do these things.

- **Keylogger hooks.** Our `keylog_start` command uses `pynput` to hook keyboard events. On Linux, this involves reading from `/dev/input/` devices or using X11 input extensions. On Windows, it would use `SetWindowsHookEx`. EDR products specifically watch for input hook installation because legitimate applications rarely need to intercept all keystrokes.

**Endpoint Detection Artifacts**

- **Persistence artifacts.** Defenders monitor cron tabs, systemd services, registry run keys, and scheduled tasks for unauthorized changes. A new `@reboot` cron entry pointing to a Python script in an unusual location is an obvious indicator of compromise (IOC).

- **Suspicious files on disk.** Our beacon sits on disk as a regular Python file. File integrity monitoring (FIM) tools notice new files in unexpected locations. Antivirus and EDR products scan files against known signatures and behavioral heuristics.

- **Process injection indicators.** Advanced C2 implants inject their code into legitimate processes (like `svchost.exe` or `explorer.exe`) to hide. Our beacon does not do this, which means the `python3` process running `beacon.py` is visible in process listings. That makes it easier to find but also means we are not teaching process injection techniques, which is appropriate for a beginner project.

### Why Our Project Is Easy to Detect

This is intentional, and it is important to be honest about the limitations:

**No TLS.** Our WebSocket connection uses `ws://` (plain text) in development, not `wss://` (TLS-encrypted). Any network monitoring tool can read the raw WebSocket frames. In a real engagement, all C2 traffic would be encrypted with TLS at minimum.

**Fixed XOR key.** The key is set in the configuration and never changes. If a defender captures one message and determines the key (which is straightforward given the known plaintext attack described above), they can decode all past and future messages. Real C2 frameworks rotate encryption keys per session or per message.

**No process injection or hollowing.** Our beacon runs as its own visible process. A defender running `ps aux | grep python` or checking the process list in a task manager will see it. Advanced implants inject into trusted processes so they inherit that process's reputation and visibility.

**No AMSI bypass or EDR evasion.** On Windows, the Antimalware Scan Interface (AMSI) lets security products inspect scripts before execution. Advanced C2 frameworks include AMSI bypass techniques. Our project does not address this at all.

**No domain fronting or traffic blending.** The beacon connects directly to the C2 server's address. Sophisticated C2 setups use domain fronting (routing traffic through CDN infrastructure so the visible domain differs from the actual destination) or mimic legitimate application traffic patterns.

**Beacon file sits plainly on disk.** No packing, no obfuscation, no fileless execution. The source code of the beacon is readable by anyone with filesystem access.

All of these limitations are deliberate. The goal of this project is to teach you how C2 architecture works. Once you understand the server-beacon-operator pattern, the encoding pipeline, the task queue model, and the detection surface, you have the foundation to understand what more advanced frameworks do and why. Teaching evasion techniques in a beginner project would prioritize the wrong things.

---

## Industry Standards and Frameworks

### MITRE ATT&CK

We have referenced MITRE ATT&CK throughout this document, but it deserves its own section.

ATT&CK stands for Adversarial Tactics, Techniques, and Common Knowledge. The framework is maintained by The MITRE Corporation and is freely available at [https://attack.mitre.org/](https://attack.mitre.org/).

The framework is organized in a matrix:

- **Tactics** are the columns. They represent the "why" of an attack. Examples: Initial Access, Execution, Persistence, Privilege Escalation, Defense Evasion, Credential Access, Discovery, Lateral Movement, Collection, Exfiltration, Command and Control.

- **Techniques** are the cells under each tactic. They represent the "how." Example: under Execution, you find T1059 (Command and Scripting Interpreter), T1053 (Scheduled Task/Job), T1569 (System Services), and many others.

- **Sub-techniques** add specificity. T1059.001 is PowerShell specifically. T1059.004 is Unix Shell. T1053.003 is Cron.

- **Procedures** are real-world examples of a technique being used by a specific threat group or malware family.

When you build detections, you think in terms of ATT&CK coverage. "We can detect T1059.001 (PowerShell execution) and T1053.003 (cron persistence) but we have no coverage for T1055 (process injection)." This gap analysis drives security investment decisions.

Our project touches these tactic categories:
- **Execution** (shell command)
- **Discovery** (sysinfo, proclist)
- **Collection** (screenshot, keylogging)
- **Exfiltration** (download)
- **Persistence** (cron)
- **Command and Control** (upload, sleep, and the entire beacon-server communication model)

### The Pyramid of Pain

David Bianco published the Pyramid of Pain in 2013 to describe how different types of indicators affect an attacker when defenders use them for detection. The pyramid has six levels, from easiest to hardest for defenders to use (and from least to most painful for attackers to change):

```
        /\
       /  \
      / TTPs \          <-- Very painful to change
     /--------\
    /  Tools   \        <-- Challenging
   /------------\
  / Network/Host\      <-- Annoying
 /  Artifacts    \
/----------------\
/ Domain Names    \     <-- Simple (buy new domain)
/------------------\
/ IP Addresses      \   <-- Easy (get new IP)
/--------------------\
/ Hash Values         \  <-- Trivial (recompile)
```

Here is how C2 infrastructure maps to this pyramid:

**Hash Values (trivial).** If defenders detect our beacon by its file hash, the attacker recompiles with a minor change and gets a new hash. This is the lowest value detection method.

**IP Addresses (easy).** If defenders block the C2 server's IP address, the attacker spins up a new server on a different IP. Cloud infrastructure makes this take minutes.

**Domain Names (simple).** Blocking the C2 domain is slightly more painful because the attacker needs to register new domains and reconfigure beacons. But domains are cheap and plentiful.

**Network Artifacts (annoying).** This is where things start to matter. If defenders detect the beacon's specific WebSocket frame pattern, the Base64-encoded XOR payloads, or the beaconing interval distribution, the attacker has to modify the protocol. That requires development effort. For our project, the encoding scheme and message format are network artifacts.

**Tools (challenging).** Detecting the C2 framework itself (not just its network traffic, but its capabilities and behavior patterns) forces the attacker to switch tools entirely. Moving from Cobalt Strike to Sliver because Cobalt Strike is too heavily signatured is a real cost.

**TTPs (very painful).** Tactics, Techniques, and Procedures are at the top. If defenders detect "any process that establishes a persistent outbound WebSocket connection and periodically spawns shell commands," the attacker cannot just change a tool or a domain. They have to fundamentally change their operational approach. This is the holy grail of detection engineering.

The lesson: detecting our beacon by its XOR key or file hash is low value. Detecting it by its behavioral pattern (periodic WebSocket connection + shell spawning + file access + cron modification) is high value because those behaviors persist regardless of what encoding scheme or IP address the attacker uses.

---

## Testing Your Understanding

Work through these questions before moving to the next section. If you can answer all five without looking back at the text, you have a solid grasp of the fundamentals.

**1. Why do beacons initiate outbound connections instead of the server connecting inbound?**

Corporate firewalls block unsolicited inbound connections. Workstations sit behind NAT without public IP addresses. Outbound connections on standard ports (80, 443) are typically allowed because employees need web access. By having the beacon call out, the C2 traffic blends with normal web traffic and bypasses perimeter security controls that only filter inbound connections.

**2. What is the purpose of jitter in a beacon's sleep interval?**

Jitter adds randomness to the check-in timing. Without jitter, a beacon sleeping for exactly 3 seconds creates a perfectly periodic traffic pattern that is trivially detectable by network monitoring tools. With 30% jitter, the interval varies between 2.1 and 3.9 seconds, making the pattern statistically harder to identify as automated beaconing.

**3. How does XOR encoding differ from real encryption like AES-256?**

XOR with a repeating key is vulnerable to known plaintext attacks and frequency analysis. If you know any portion of the plaintext (and you do, because JSON messages have predictable structure), you can recover the key. AES-256 is a block cipher that uses multiple rounds of substitution, permutation, and mixing operations. It is resistant to all known cryptanalytic attacks when used correctly with proper key management, random initialization vectors, and appropriate cipher modes. XOR is obfuscation. AES is encryption. They are fundamentally different in security guarantees.

**4. Name three ways a defender could detect our beacon's traffic on a network.**

Any three of: (a) Identifying periodic WebSocket connections with semi-regular timing patterns. (b) Detecting Base64-encoded payloads in WebSocket text frames. (c) Observing the process spawning shell commands after receiving WebSocket messages. (d) Monitoring for new cron entries created by non-standard processes. (e) Flagging the unencrypted (`ws://`) WebSocket connection to an external server. (f) Identifying the beacon process by name in process listings.

**5. Why does our beacon use exponential backoff for reconnection?**

Two reasons. First, it prevents the beacon from hammering a server that is temporarily down, which would create visible network noise and look like scanning or DDoS activity. Second, if many beacons lose connection simultaneously (say the server restarts), exponential backoff with some randomness spreads their reconnection attempts over time rather than having all of them hit the server at once. The cap at 300 seconds ensures the beacon eventually reconnects in a reasonable timeframe even after extended outages.

---

## Further Reading

- **MITRE ATT&CK Framework:** [https://attack.mitre.org/](https://attack.mitre.org/) - The definitive reference for adversary tactics and techniques. Start with the Enterprise matrix and explore the techniques our project implements.

- **The C2 Matrix:** [https://www.thec2matrix.com/](https://www.thec2matrix.com/) - A community-maintained spreadsheet comparing dozens of C2 frameworks by features, protocols, and capabilities. Useful for understanding the landscape beyond the frameworks mentioned in this document.

- **Cobalt Strike Documentation:** [https://www.cobaltstrike.com/](https://www.cobaltstrike.com/) - Understanding Cobalt Strike is important because it set the standard that most modern C2 frameworks follow. Even if you never use it, knowing its concepts (malleable profiles, named pipes, spawn-to processes) gives you vocabulary the industry uses daily.

- **David Bianco's Pyramid of Pain:** The original blog post from 2013 that defined how different indicator types affect adversaries. Search for "David Bianco Pyramid of Pain" to find the original and many derivatives.

- **SANS Reading Room - C2 Analysis:** SANS publishes research papers on C2 detection and analysis. Their papers on network threat hunting and beaconing detection are particularly relevant to what we have built here.

- **Red Canary Threat Detection Report:** Published annually, this report covers the most prevalent ATT&CK techniques observed in real incidents. It provides concrete examples of how the techniques in our project manifest in actual breaches.
