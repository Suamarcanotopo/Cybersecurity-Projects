# Extension Challenges

You've built the base project. Now make it yours by extending it with new features.

These challenges are ordered by difficulty. Start with the easier ones to build confidence, then tackle the harder ones when you want to dive deeper.

## Easy Challenges

### Challenge 1: Add Clipboard Monitoring

**What to build:**
Capture clipboard contents whenever the user copies or pastes text. Log clipboard data alongside keystrokes to catch passwords users paste from password managers.

**Why it's useful:**
Many users never type their passwords, they paste them. Keyloggers miss these credentials entirely. Clipboard monitoring catches data that keyboard capture alone can't see. In the 2020 SolarWinds breach, attackers used clipboard stealing malware alongside keyloggers.

**What you'll learn:**
- Platform clipboard APIs (pyperclip library or platform-specific approaches)
- Polling vs event-driven clipboard monitoring
- Handling binary clipboard data (images, files)

**Hints:**
- Install pyperclip: `pip install pyperclip`
- Create a `ClipboardMonitor` class similar to `WindowTracker` (`keylogger.py:155`)
- Poll clipboard every 0.5 seconds in a separate thread
- Compare current clipboard to previous, log if different
- Store in LogManager like keyboard events

**Test it works:**
Copy some text (Ctrl+C), check the log file for `[CLIPBOARD] text you copied`. Paste some text (Ctrl+V), verify the log shows both the paste keystroke and clipboard contents.

### Challenge 2: Filter Sensitive Applications

**What to build:**
Add configuration to skip logging keystrokes from specific applications like password managers (1Password, LastPass, KeePass). This reduces log size and focuses on high-value targets.

**Why it's useful:**
Password managers show random strings when users unlock them. Logging these wastes space and makes analysis harder. Real malware often ignores password managers and focuses on browsers, email, and banking apps.

**What you'll learn:**
- String matching and filtering
- Configuration management patterns
- Trade-offs between logging everything vs targeted capture

**Hints:**
- Add `excluded_apps` list to `KeyloggerConfig` (`keylogger.py:108`)
- In `_on_press`, check if `self._current_window` contains any excluded app name (`keylogger.py:428`)
- Use case-insensitive matching: `window_title.lower()` contains `"1password"`
- Test with config: `KeyloggerConfig(excluded_apps=["1password", "keepass"])`

**Test it works:**
Add "notepad" to excluded apps. Open Notepad, type some text. Check logs, verify Notepad keystrokes aren't recorded. Open Chrome, type text, verify it IS recorded.

### Challenge 3: Add Keystroke Statistics

**What to build:**
Track and display statistics: total keystrokes captured, keystrokes per application, most common keys pressed, logging uptime. Print stats when the keylogger shuts down.

**Why it's useful:**
Statistics help attackers prioritize which logs to review first. If 90% of keystrokes are in Chrome, analyze Chrome logs for credentials. Uptime shows how long the malware has been running undetected.

**What you'll learn:**
- Aggregating data in real time
- Using collections.Counter for frequency analysis
- Clean statistics display formatting

**Hints:**
- Add a `Statistics` class with counters: `total_keys`, `keys_per_app`, `special_key_count`
- Increment counters in `_on_press` before writing to LogManager (`keylogger.py:457`)
- Use `collections.Counter` for `keys_per_app` tracking
- Print stats in `stop()` method (`keylogger.py:516-533`)
- Calculate uptime: `datetime.now() - start_time`

**Test it works:**
Run keylogger, type in multiple applications. Stop with Ctrl+C. Verify output shows:
```
Statistics:
Total keystrokes: 247
Uptime: 0:05:32
Top applications:
  chrome.exe - Gmail: 156 keystrokes
  code.exe - keylogger.py: 91 keystrokes
```

## Intermediate Challenges

### Challenge 4: Encrypt Log Files

**What to build:**
Encrypt log files using AES-256 so disk scans don't find sensitive keywords like "password" or "creditcard". Decrypt on exfiltration or when attacker retrieves logs.

**Real world application:**
Modern EDR systems scan disk for IOCs (Indicators of Compromise) like common passwords or credit card patterns. Encrypted logs evade these scans. The Carbanak malware group used encrypted logs to persist on victim machines for years.

**What you'll learn:**
- Symmetric encryption with AES
- Key derivation from passwords (PBKDF2)
- File encryption patterns
- Trade-offs between security and detectability

**Implementation approach:**

1. **Add encryption to LogManager** (modify `keylogger.py:222-296`)
   - Install cryptography: `pip install cryptography`
   - Import `from cryptography.fernet import Fernet`
   - Generate key in `__init__`: `self.key = Fernet.generate_key()`
   - Encrypt data before writing: `encrypted = fernet.encrypt(log_string.encode())`

2. **Integrate with existing logging**
   - Modify `write_event()` to encrypt before writing
   - Store key in config file or hardcode (educational purposes)
   - Add `decrypt_log(log_path, key)` utility function

3. **Test edge cases:**
   - What if the key is lost?
   - How do you decrypt multiple rotated log files?
   - Does encryption break log rotation size calculations?

**Hints:**
- Fernet provides authenticated encryption (prevents tampering)
- Encrypt each line separately so corruption doesn't destroy entire file
- Store key in `KeyloggerConfig.encryption_key`
- Add `--decrypt` command line flag to decrypt and print logs

**Extra credit:**
Use asymmetric encryption (RSA). Generate key pair, encrypt logs with public key, only attacker with private key can decrypt. This prevents victim from reading their own logs even if they find them.

### Challenge 5: Add Screenshot Capture on Keywords

**What to build:**
Automatically capture screenshots when sensitive keywords are typed (password, credit, ssn, secret). Helps attackers see context beyond just keystrokes.

**Real world application:**
Keyloggers show what was typed but not what was on screen. Screenshots reveal form layouts, email contents, and visual context. The DarkHotel APT group combined keylogging with screenshot capture to steal business travelers' credentials in hotel WiFi.

**What you'll learn:**
- Screen capture APIs across platforms
- Keyword detection in keystroke streams
- Efficient image storage and compression
- Balancing file size with screenshot quality

**Implementation approach:**

1. **Add screenshot capability**
   - Install Pillow: `pip install pillow`
   - Install pyscreenshot: `pip install pyscreenshot`
   - Create `ScreenshotCapture` class similar to WindowTracker

2. **Detect keywords in keystrokes**
   - Maintain sliding window of last 20 characters
   - Check if window contains any trigger keywords
   - Trigger keywords: ["password", "credit", "card", "ssn", "secret"]

3. **Capture and save**
   - Call `pyscreenshot.grab()` when keyword detected
   - Save as PNG in same directory as logs
   - Include timestamp in filename: `screenshot_20250131_143045.png`
   - Compress with `quality=75` to reduce file size

**Hints:**
```python
# Add to Keylogger class
def _check_keywords(self, key_str: str) -> None:
    self._recent_keys.append(key_str)
    if len(self._recent_keys) > 20:
        self._recent_keys.pop(0)

    recent_text = ''.join(self._recent_keys).lower()
    for keyword in self.config.trigger_keywords:
        if keyword in recent_text:
            self.screenshot_capture.capture(keyword)
```

- Look at LogManager's file creation pattern (`keylogger.py:240-246`)
- Call from `_on_press` after logging keystroke
- Throttle screenshots: Don't capture more than 1 per 5 seconds even if keyword repeated

**Gotchas:**
- Screenshots are large (1-5MB each), will fill disk quickly
- Capturing screenshot blocks the callback thread, might drop keystrokes
- Some platforms require screen recording permissions (macOS)

## Advanced Challenges

### Challenge 6: Add Process Injection for Stealth

**What to build:**
Inject the keylogger code into a legitimate process (explorer.exe, chrome.exe) so Task Manager shows the keylogger running as part of a trusted application.

**Why this is hard:**
Requires understanding process memory layout, DLL injection techniques, and platform-specific APIs. Detection becomes much harder when malicious code runs inside trusted processes.

**What you'll learn:**
- Process injection techniques (DLL injection, process hollowing, reflective loading)
- Windows API calls (OpenProcess, VirtualAllocEx, WriteProcessMemory, CreateRemoteThread)
- Memory protection and DEP (Data Execution Prevention) bypasses
- Advanced evasion tactics

**Architecture changes needed:**

```
Current:
  python.exe → keylogger.py

New:
  python.exe → inject.py → explorer.exe (injected code runs here)
```

**Implementation steps:**

1. **Research phase**
   - Read about DLL injection on Windows
   - Understand process memory layout
   - Study CreateRemoteThread API
   - Look at reference implementations (Metasploit's injector modules)

2. **Design phase**
   - Decide: Inject Python interpreter or compile to DLL?
   - Consider: How to maintain remote communication with injected code
   - Plan: How to handle crash recovery if injected process dies

3. **Implementation phase**
   - Create DLL that contains keylogger logic
   - Write injector script that loads DLL into target process
   - Handle 32-bit vs 64-bit process compatibility
   - Add error handling for injection failures

4. **Testing phase**
   - Test injection into notepad.exe (simple target)
   - Verify keystrokes are still captured after injection
   - Check Task Manager shows keylogger code running in target process

**Gotchas:**
- Modern Windows has protections (DEP, ASLR, CFG) that block simple injection
- Antivirus detects DLL injection techniques aggressively
- Injecting into protected processes (csrss.exe, lsass.exe) requires SYSTEM privileges
- Process crashes kill your keylogger, need recovery mechanism

**Resources:**
- "Windows Internals" by Mark Russinovich - Chapter on process memory
- "The Rootkit Arsenal" by Bill Blunden - DLL injection techniques
- MITRE ATT&CK T1055 - Process Injection technique documentation

### Challenge 7: Build a Command and Control Server

**What to build:**
Create a Flask server that receives webhook data from multiple infected machines, stores it in a database, and provides a web UI for browsing captured keystrokes by victim, application, or keyword.

**Why this is hard:**
Requires full stack development (backend, database, frontend), handling concurrent connections from multiple keyloggers, implementing authentication, and creating a usable interface for log analysis.

**What you'll learn:**
- Web framework development (Flask/FastAPI)
- Database design for time-series data (PostgreSQL, MongoDB)
- User authentication and authorization
- Building real-time dashboards
- Secure communication between malware and C2

**High level architecture:**

```
┌─────────────────┐
│   Victim 1      │
│   (Keylogger)   │
└────────┬────────┘
         │ HTTPS POST
         ▼
┌─────────────────┐      ┌──────────────┐
│  C2 Server      │◄────►│  PostgreSQL  │
│  (Flask API)    │      │  (Storage)   │
└────────┬────────┘      └──────────────┘
         │
         ▼
┌─────────────────┐
│   Web UI        │
│   (Dashboard)   │
└─────────────────┘
```

**Implementation phases:**

**Phase 1: Backend API** (8-12 hours)
- Flask app with `/webhook` endpoint that receives keylogger data
- Authentication using API keys (validate before accepting data)
- PostgreSQL schema: `victims` table (victim_id, hostname, ip, first_seen, last_seen)
- `keystrokes` table (id, victim_id, timestamp, key, window_title, key_type)
- Insert keystroke batches efficiently (bulk insert)

**Phase 2: Data Analysis** (6-8 hours)
- Query endpoints: `/api/victims` (list all infected machines)
- `/api/keystrokes?victim_id=X&start_date=Y` (get keystroke timeline)
- `/api/search?keyword=password` (find specific terms across all victims)
- Aggregation queries: Top applications per victim, keystroke volume over time

**Phase 3: Web Dashboard** (10-15 hours)
- React or vanilla JS frontend
- Victim list view (table showing all infected machines, last activity)
- Keystroke timeline view (chronological log with filters)
- Search interface (find "password", "credit card" across all logs)
- Live updates (WebSocket or polling for new keystroke batches)

**Phase 4: Security Hardening** (5-7 hours)
- HTTPS only (Let's Encrypt certificates)
- API key rotation mechanism
- Rate limiting (prevent abuse/DDoS)
- Input validation (prevent SQL injection from malicious keylogger data)

**Testing strategy:**
- Load test with 10 concurrent keyloggers sending 1000 keystrokes/minute each
- Security test: Try SQL injection in keystroke data, verify it's sanitized
- UI test: Verify search works with 1 million+ keystrokes in database
- Performance: Query response time should be <200ms even with large datasets

**Known challenges:**
1. **Database schema optimization**
   - Problem: Querying millions of keystrokes is slow without indexes
   - Hint: Index on (victim_id, timestamp) for timeline queries

2. **Real-time updates**
   - Problem: Polling every second creates high server load
   - Hint: Use WebSockets or Server-Sent Events for live data

3. **Secure communication**
   - Problem: Unencrypted webhooks expose keystroke data to network monitoring
   - Hint: Use HTTPS with certificate pinning, encrypt payload with shared secret

**Success criteria:**
Your implementation should:
- [ ] Accept webhook POSTs from multiple keyloggers simultaneously
- [ ] Store keystrokes efficiently (100+ keystrokes/second sustained)
- [ ] Provide search across all victims in <1 second
- [ ] Display live keystroke feed with <5 second latency
- [ ] Handle 10,000+ keystrokes per victim without performance degradation
- [ ] Authenticate requests (prevent unauthorized data submission)

## Expert Challenges

### Challenge 8: Kernel-Level Keystroke Capture

**What to build:**
Write a kernel driver that intercepts keyboard events at the kernel level, below where EDR and antivirus can see. This requires kernel-mode programming and is Windows-only.

**Estimated time:**
2-3 weeks for someone with C/C++ experience, longer for Python-only developers

**Prerequisites:**
You should have completed previous challenges and understand Windows internals, C programming, and kernel debugging. This is genuinely hard and dangerous (kernel bugs crash the system).

**What you'll learn:**
- Windows kernel driver development (WDM or WDF framework)
- Keyboard filter drivers and the input stack
- Kernel mode debugging with WinDbg
- Code signing requirements for drivers
- How EDR detects kernel mode malware

**Planning this feature:**

Before you code, think through:
- How does this affect existing functionality? (Replaces pynput entirely)
- What are the performance implications? (Kernel code must be fast, bugs crash the system)
- How do you migrate existing users? (Requires driver installation, admin rights)
- What's your rollback plan if it breaks? (Test mode Windows, safe mode recovery)

**High level architecture:**

```
┌──────────────────────────────────────┐
│         User Mode                    │
│  ┌──────────────────────────────┐   │
│  │  Keylogger Service           │   │
│  │  (Receives from driver)      │   │
│  └──────────────────────────────┘   │
└──────────────┬───────────────────────┘
               │ IOCTL
┌──────────────┴───────────────────────┐
│         Kernel Mode                  │
│  ┌──────────────────────────────┐   │
│  │  Keyboard Filter Driver      │   │
│  │  (Intercepts keystrokes)     │   │
│  └──────────────────────────────┘   │
│               ↑                      │
│               │                      │
│  ┌──────────────────────────────┐   │
│  │  i8042prt (Keyboard Driver)  │   │
│  └──────────────────────────────┘   │
└──────────────────────────────────────┘
```

**Implementation phases:**

**Phase 1: Foundation** (40-60 hours)
- Set up Windows Driver Kit (WDK) development environment
- Create basic keyboard filter driver (read Microsoft's kbfiltr sample)
- Understand IOCTL communication between kernel and user mode
- Implement driver loading/unloading

**Phase 2: Keystroke Interception** (30-40 hours)
- Hook into keyboard driver stack using filter driver
- Intercept IRP_MJ_READ requests
- Extract scan codes and convert to VK codes
- Buffer keystrokes in kernel memory (non-paged pool)

**Phase 3: User Mode Communication** (20-30 hours)
- Create IOCTL interface for user mode to read keystroke buffer
- Modify keylogger.py to read from driver instead of pynput
- Handle driver errors and crashes gracefully
- Implement automatic driver restart on failure

**Phase 4: Stealth and Persistence** (30-40 hours)
- Hide driver from EnumDeviceDrivers API
- Hook IRP_MJ_DEVICE_CONTROL to hide from driver enumeration
- Add to boot-start drivers for persistence
- Sign driver with valid certificate (required for Windows 10+)

**Known challenges:**

1. **Code Signing Requirement**
   - Problem: Windows requires drivers to be signed, test signing works only in test mode
   - Hint: Apply for legitimate signing certificate or use test mode during development

2. **Kernel Debugging is Essential**
   - Problem: Kernel bugs cause BSOD (blue screen of death), no error messages
   - Hint: Set up kernel debugging with WinDbg over network or serial

3. **Performance Critical**
   - Problem: Slow kernel code causes system lag, spinning mouse cursor
   - Hint: Never use blocking operations in kernel, use deferred procedure calls

4. **EDR Detection**
   - Problem: Modern EDR detects keyboard filter drivers instantly
   - Hint: Study rootkit techniques, DKOM (Direct Kernel Object Manipulation)

**Success criteria:**
Your implementation should:
- [ ] Intercept keystrokes before user mode sees them
- [ ] Run on Windows 10 and Windows 11
- [ ] Survive reboots (persistence)
- [ ] Cause no noticeable performance impact
- [ ] Evade basic EDR detection (at least temporarily)
- [ ] Gracefully handle driver unload without BSOD
- [ ] Pass Driver Verifier stress testing

**Resources:**
- Windows Kernel Programming by Pavel Yosifovich
- Rootkits: Subverting the Windows Kernel by Greg Hoglund
- Windows Internals 7th Edition
- OSR Online (driver development forums)

### Challenge 9: Multi-Protocol Exfiltration

**What to build:**
Support multiple exfiltration channels (HTTP, DNS tunneling, email, cloud storage) with automatic failover. If primary channel (webhook) is blocked, try DNS, then email, then Dropbox.

**Estimated time:**
1-2 weeks

**Prerequisites:**
Understanding of network protocols, DNS, SMTP, cloud storage APIs. Should have completed webhook challenges first.

**What you'll learn:**
- DNS tunneling techniques for data exfiltration
- SMTP email automation and stealth
- Cloud API abuse (Dropbox, Google Drive, Pastebin)
- Covert channels and steganography
- Protocol-aware firewall evasion

**High level architecture:**

```
┌─────────────────────────────────────┐
│      Exfiltration Manager           │
│   (Priority-based channel selection) │
└───┬───────┬────────┬─────────┬──────┘
    │       │        │         │
    ▼       ▼        ▼         ▼
┌────────┐ ┌─────┐ ┌──────┐ ┌──────┐
│Webhook │ │ DNS │ │Email │ │Dropbox│
│Channel │ │Tunnel│ │SMTP │ │ API  │
└────────┘ └─────┘ └──────┘ └──────┘
```

**Implementation phases:**

**Phase 1: Channel Abstraction** (10-15 hours)
- Define `ExfiltrationChannel` base class
- Methods: `send(data)`, `test_connectivity()`, `get_max_payload_size()`
- Implement `ChannelManager` that maintains list of channels by priority
- Automatic failover: If channel fails, mark as down, try next

**Phase 2: DNS Tunneling** (15-20 hours)
- Encode keystroke data in DNS queries (base32 or base64)
- Split large payloads across multiple DNS queries
- Use TXT record queries to exfiltrate: `<data>.attacker.com`
- Receive responses via authoritative DNS server you control
- Handle rate limiting (max 10 queries/second to avoid suspicion)

**Phase 3: Email Exfiltration** (10-12 hours)
- SMTP client that sends logs as email attachments
- Use throwaway Gmail/Outlook accounts
- Disguise emails as legitimate traffic (Subject: "Daily Backup Report")
- Compress logs before attaching (gzip)
- Throttle: Max 1 email per hour

**Phase 4: Cloud Storage** (8-10 hours)
- Dropbox API integration
- Upload logs to shared folder
- Use legitimate API client (looks like Dropbox Desktop app)
- Rotate upload accounts to avoid detection

**Phase 5: Failover Logic** (5-8 hours)
- Test channels in order before actual exfiltration
- Mark channel as down if test fails
- Retry down channels every 30 minutes
- Maintain local buffer if all channels fail

**Known challenges:**

1. **DNS Tunneling Detection**
   - Problem: High volume of DNS queries to single domain raises flags
   - Hint: Rotate through multiple domains, throttle queries

2. **Email Spam Filters**
   - Problem: Email providers detect and block automated emails
   - Hint: Randomize send times, use real-looking subject lines

3. **API Rate Limits**
   - Problem: Cloud APIs throttle high-frequency uploads
   - Hint: Respect rate limits, batch uploads

**Success criteria:**
- [ ] Support 4+ exfiltration channels
- [ ] Automatic failover in <30 seconds
- [ ] DNS tunnel payload >1KB per query
- [ ] Email exfiltration evades Gmail spam filter
- [ ] All channels tested and working on real network
- [ ] Logs don't pile up if channels temporarily down

## Mix and Match

Combine features for bigger projects:

**Project Idea 1: Complete Stealth Keylogger**
- Combine Challenge 4 (Log Encryption)
- Add Challenge 5 (Screenshot Capture)
- Add Challenge 6 (Process Injection)
- Result: Keylogger that hides in trusted process, captures context with screenshots, stores encrypted logs

**Project Idea 2: Cloud-Backed Corporate Spy**
- Combine Challenge 7 (C2 Server)
- Add Challenge 9 (Multi-Protocol Exfiltration)
- Add Challenge 2 (Application Filtering) to target specific corporate apps
- Result: Enterprise-grade spyware with cloud C2, multiple exfiltration paths, filtered logging

## Real World Integration Challenges

### Integrate with Discord Webhook

**The goal:**
Send keystroke logs to Discord channel via webhook. Provides free, real-time notifications with no server setup required.

**What you'll need:**
- Discord account
- Discord server (create one)
- Webhook URL (Server Settings → Integrations → Webhooks)

**Implementation plan:**
1. Modify `WebhookDelivery` to format payload for Discord API
2. Discord expects `{"content": "text"}` format
3. Format keystrokes as code blocks: "```[2025-01-31] password123```"
4. Add rate limit handling (Discord limits to 5 requests/second)

**Watch out for:**
- Discord webhooks have 2000 character limit per message
- High volume keystrokes might hit rate limits
- Webhook URL in code is exposed if victim finds the file

### Deploy to Raspberry Pi

**The goal:**
Run keylogger on Raspberry Pi to capture keystrokes from a USB keyboard plugged into it. Useful for hardware-based attacks (Pi hidden in conference room).

**What you'll learn:**
- USB HID protocol
- Linux udev rules for device permissions
- Headless Raspberry Pi setup
- Network exfiltration over WiFi

**Steps:**
1. Install Raspberry Pi OS Lite
2. Set up Python and dependencies with `just setup`
3. Configure keyboard permissions: `/dev/input/event*`
4. Run keylogger as systemd service
5. Exfiltrate over WiFi to remote C2

**Production checklist:**
- [ ] Auto-start on boot via systemd
- [ ] Reconnect to WiFi if connection drops
- [ ] Handle keyboard disconnect/reconnect
- [ ] Buffer logs locally if network unavailable
- [ ] Minimize power consumption for battery operation

## Performance Challenges

### Challenge: Handle 200+ Keystrokes Per Second

**The goal:**
Optimize the keylogger to handle extreme typing speeds without dropping keystrokes or causing lag. Gamers and stenographers can exceed 200 keystrokes/second.

**Current bottleneck:**
At high speeds, file I/O and window tracking lag behind keystroke rate. Events queue up, callback blocks, pynput drops events.

**Optimization approaches:**

**Approach 1: Async File I/O**
- How: Use `aiofiles` library for non-blocking writes
- Gain: File writes don't block keyboard callback
- Tradeoff: Complexity increases, need to manage event loop

**Approach 2: Lock-Free Queue**
- How: Use `queue.Queue` instead of locking on every write
- Producer (callback) adds to queue, consumer (writer thread) drains queue
- Gain: Callback completes in <1ms, no blocking
- Tradeoff: Additional thread, memory usage for queue

**Approach 3: Batch Writes**
- How: Buffer 100 keystrokes in memory, write all at once
- Gain: Amortize file I/O cost across many events
- Tradeoff: Data loss if crash before batch written

**Benchmark it:**
```bash
# Simulate high speed typing
python -c "
from pynput.keyboard import Controller, Key
import time

keyboard = Controller()
start = time.time()
for i in range(1000):
    keyboard.press('a')
    keyboard.release('a')
print(f'Sent 1000 keys in {time.time() - start:.2f}s')
"
```

Target metrics:
- Latency: <2ms per keystroke processing
- Throughput: Handle 200 keystrokes/second sustained
- Memory: <100MB RAM usage even under load

## Security Challenges

### Challenge: Add Anti-Forensics

**What to implement:**
Delete log files on specific trigger (panic key, USB removal, process termination). Leave no evidence if victim becomes suspicious.

**Threat model:**
This protects against:
- Forensic analysis after keylogger is discovered
- Disk scans for sensitive keywords
- Investigators recovering deleted files

**Implementation:**
1. Add `panic_key` to config (default: F10)
2. In `_on_press`, check for panic key
3. If detected, call `_secure_delete_logs()`
4. Overwrite file contents with random data 7 times (DoD 5220.22-M standard)
5. Delete files
6. Exit immediately

**Testing the security:**
- Trigger panic deletion
- Use file recovery tools (PhotoRec, Recuva) to attempt recovery
- Verify files cannot be recovered
- Check if fragments remain in $MFT (Windows) or journal (Linux)

### Challenge: Pass AMSI and ETW Bypass

**The goal:**
Evade Windows Antimalware Scan Interface (AMSI) and Event Tracing for Windows (ETW) which detect malicious PowerShell and .NET code.

**Threat model:**
Modern Windows Defender uses AMSI to scan scripts before execution. ETW logs suspicious API calls. Bypassing both significantly improves stealth.

**Implementation:**
1. Research AMSI bypass techniques (amsi.dll patching, reflection)
2. Implement ETW blind spots (patch EtwEventWrite)
3. Test against Windows Defender in real-time protection mode
4. Verify Sysmon doesn't log keylogger execution

**Remediation:**
Study current bypass techniques on GitHub, test against latest Windows version, understand why they work, implement your own variant.

## Contribution Ideas

Finished a challenge? Share it back:

1. **Fork the repo**
2. **Implement your extension** in a new branch (`git checkout -b feature/clipboard-monitoring`)
3. **Document it** - Add to learn folder, update README
4. **Submit a PR** with:
   - Your implementation
   - Tests proving it works
   - Documentation explaining the feature
   - Example usage

Good extensions might get merged into the main project and help future learners.

## Challenge Yourself Further

### Build Something New

Use the concepts you learned here to build:
- **Network Traffic Analyzer** - Capture and analyze network packets instead of keystrokes
- **Process Monitor** - Track process creation, termination, and behavior
- **File System Watcher** - Monitor file access, modifications, and deletions

### Study Real Implementations

Compare your implementation to production keyloggers:

- **DarkComet RAT** - Study how commercial RATs implement keylogging alongside other malware features
- **Empire Framework** - Look at keylogging modules in post-exploitation frameworks
- **Public PoCs on GitHub** - Search for keylogger implementations, read their code, understand their tradeoffs

Read their code, understand their tradeoffs, steal their good ideas (for educational purposes).

### Write About It

Document your extension:
- Blog post explaining what you built and why
- Tutorial for others to follow along
- Comparison with alternative approaches
- Security analysis: How would you detect your own malware?

Teaching others is the best way to verify you understand it.

## Getting Help

Stuck on a challenge?

1. **Debug systematically**
   - What did you expect to happen?
   - What actually happened?
   - What's the smallest test case that reproduces it?
   - What have you already tried?

2. **Read the existing code**
   - How does `LogManager` handle similar functionality?
   - Could `WebhookDelivery` pattern apply to your challenge?
   - Check tests for examples of component usage

3. **Search for similar problems**
   - Stack Overflow: [python] keylogger [specific issue]
   - GitHub: Search for "keylogger" + your technology
   - Reddit r/netsec: Search for real-world implementations

4. **Ask for help**
   - Post in discussions with specific details
   - Include: What you tried, what happened, what you expected
   - Provide minimal reproducible code snippet
   - Don't just paste error messages without context

## Challenge Completion

Track your progress:

- [ ] Easy Challenge 1: Clipboard Monitoring
- [ ] Easy Challenge 2: Filter Sensitive Applications
- [ ] Easy Challenge 3: Keystroke Statistics
- [ ] Intermediate Challenge 4: Encrypt Log Files
- [ ] Intermediate Challenge 5: Screenshot Capture on Keywords
- [ ] Advanced Challenge 6: Process Injection
- [ ] Advanced Challenge 7: Command and Control Server
- [ ] Expert Challenge 8: Kernel-Level Keystroke Capture
- [ ] Expert Challenge 9: Multi-Protocol Exfiltration

Completed all of them? You've mastered this project. Time to build something new or contribute back to the community with your extensions.
