# System Architecture

This document breaks down how the system is designed and why certain architectural decisions were made.

## High Level Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Operating System                       │
│                  (Keyboard Event Stream)                  │
└────────────────────────┬─────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  pynput Listener     │
              │  (Event Callbacks)   │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │     Keylogger        │
              │   (Main Controller)  │
              └─────┬────────┬───────┘
                    │        │
        ┌───────────┘        └──────────┐
        ▼                               ▼
┌───────────────┐              ┌────────────────┐
│ WindowTracker │              │  LogManager    │
│  (Platform-   │              │ (File Writing) │
│   Specific)   │              └────────┬───────┘
└───────────────┘                       │
                                        ▼
                              ┌──────────────────┐
                              │ WebhookDelivery  │
                              │  (Exfiltration)  │
                              └──────────────────┘
```

### Component Breakdown

**Keylogger (Main Controller)**
- Purpose: Orchestrates all components and handles the event processing pipeline
- Responsibilities: Receives keyboard events from pynput, processes keys, coordinates window tracking, delegates to logging and webhook delivery
- Interfaces: Exposes `start()` and `stop()` methods for lifecycle management, registers `_on_press()` callback with pynput listener
- Location: `keylogger.py:373-533`

**LogManager**
- Purpose: Manages persistent storage of keystroke events with automatic file rotation using direct file I/O
- Responsibilities: Creates timestamped log files, writes events to disk via raw file handles, monitors file size and rotates when limit reached, provides thread-safe access via locks, handles explicit file handle cleanup via `close()`
- Interfaces: `write_event(event)` for logging, `get_current_log_content()` for reading back logs, `close()` for releasing file handles
- Location: `keylogger.py:222-296`

**WebhookDelivery**
- Purpose: Handles remote exfiltration of captured keystrokes via HTTP webhooks
- Responsibilities: Buffers events to reduce network traffic, batches events before sending, uses a buffer swap pattern to deliver outside the lock, delivers JSON payloads to configured endpoint, handles delivery failures gracefully
- Interfaces: `add_event(event)` for queuing, `flush()` for forcing immediate delivery
- Location: `keylogger.py:298-371`

**WindowTracker**
- Purpose: Determines which application has focus when keystrokes occur
- Responsibilities: Platform detection (Windows/macOS/Linux), calls platform-specific APIs to get active window title, provides unified interface across platforms
- Interfaces: Static method `get_active_window()` returns current window title or None
- Location: `keylogger.py:155-219`

**KeyEvent (Data Model)**
- Purpose: Immutable representation of a single keystroke with metadata
- Responsibilities: Stores timestamp, key value, window context, and key type classification
- Interfaces: `to_dict()` for JSON serialization, `to_log_string()` for human-readable formatting
- Location: `keylogger.py:123-152`

## Data Flow

### Primary Use Case: Keystroke Capture and Logging

Step by step walkthrough of what happens when a user presses a key:

```
1. OS Keyboard Event → pynput Listener
   User presses 'a' key, OS delivers event to all registered listeners
   pynput captures event and triggers our callback

2. Listener → Keylogger._on_press() (keylogger.py:428)
   Callback receives Key or KeyCode object
   Checks if it's the toggle key (dynamically reads config toggle key) → pause/resume if so
   Checks if logging is active → early return if paused

3. Keylogger → WindowTracker.get_active_window() (keylogger.py:390)
   Calls platform-specific code to get active window
   Caches result for config.window_check_interval seconds (default 0.5) to avoid excessive API calls
   Returns window title like "Chrome - Gmail" or None

4. Keylogger → _process_key() (keylogger.py:406)
   Converts Key/KeyCode to string representation
   Looks up special keys via module-level SPECIAL_KEYS constant
   Maps special keys (Enter→"[ENTER]", Space→"[SPACE]")
   Classifies key type (CHAR, SPECIAL, UNKNOWN)

5. Keylogger → Creates KeyEvent (keylogger.py:450)
   Bundles timestamp, key string, window title, and key type
   Creates dataclass instance

6. Keylogger → LogManager.write_event() (keylogger.py:248)
   Acquires lock for thread safety
   Formats event to log string: "[2025-01-31 14:30:22][Chrome] a"
   Writes to current log file via direct file I/O (self._file.write + flush)
   Checks file size and rotates if needed

7. Keylogger → WebhookDelivery.add_event() (keylogger.py:308)
   Adds event to buffer array under lock
   Checks if buffer reached batch size (default 50)
   If full, swaps the buffer (replaces with empty list) under lock
   Delivers the batch OUTSIDE the lock via HTTP POST
```

Example with code references:
```
1. User types "p" → OS delivers KeyCode(char='p')

2. _on_press receives event (keylogger.py:428-458)
   Validates logging is active, not the toggle key

3. _update_active_window() called (keylogger.py:390-404)
   Returns "Visual Studio Code - keylogger.py"

4. _process_key(KeyCode(char='p')) → ("p", KeyType.CHAR)
   Not a special key, has .char attribute

5. KeyEvent created:
   timestamp=datetime.now()
   key="p"
   window_title="Visual Studio Code - keylogger.py"
   key_type=KeyType.CHAR

6. LogManager.write_event() (keylogger.py:248-255)
   Writes: "[2025-01-31 14:30:45][Visual Studio Code - keylogger.py] p"
   Checks: Current file is 4.2 MB, under 5 MB limit, no rotation

7. WebhookDelivery.add_event() (keylogger.py:308-324)
   Acquires lock, appends event, buffer now has 47 events
   Not yet at batch size 50, releases lock, no delivery
```

### Secondary Use Case: Log File Rotation

Step by step for when log file grows too large:

```
1. LogManager.write_event() → _check_rotation() (keylogger.py:257)
   After writing and flushing event, checks current log file size

2. _check_rotation() (keylogger.py:257-268)
   Tries to stat the file for its size
   If FileNotFoundError (file deleted externally), rotates immediately
   Otherwise reads file size: 5.1 MB (over 5 MB limit)
   Calls _rotate()

3. _rotate() (keylogger.py:270-280)
   Closes current file handle (self._file.close())
   Generates new path via _get_new_log_path()

4. _get_new_log_path() (keylogger.py:240-246)
   Generates new filename with current timestamp including microseconds
   Format: "keylog_20250131_143500_123456.txt"
   Returns Path object in log_dir

5. Opens new file handle
   self._file = open(new_path, 'a', encoding='utf-8')
   Ready for next write

6. Next write_event() call → Goes to new file
   Old file preserved with all historical keystrokes
```

## Design Patterns

### Observer Pattern (Event-Driven Architecture)

**What it is:**
The Observer pattern allows objects to subscribe to events and react when they occur. The subject (keyboard) notifies observers (our callback) without tight coupling.

**Where we use it:**
pynput's `keyboard.Listener` implements the Observer pattern (`keylogger.py:505-506`):

```python
self.listener = keyboard.Listener(on_press=self._on_press)
self.listener.start()
```

Our `_on_press` method is the observer callback. When the OS delivers a keyboard event, pynput notifies us by calling this function.

**Why we chose it:**
Observer pattern is ideal for event-driven systems where we don't control the timing of events. We can't poll the keyboard (too slow, high CPU), we need to react immediately when keys are pressed. The pattern also decouples us from pynput's implementation details.

**Trade-offs:**
- Pros: Clean separation between event source and handler, enables real-time processing, scales to multiple event types (we could add mouse events)
- Cons: Callback runs in pynput's thread so we need careful synchronization, harder to debug than sequential code, callback failures can crash the listener

### Thread Safety with Locks

**What it is:**
Multiple threads accessing shared data requires synchronization primitives like locks to prevent race conditions.

**Where we use it:**
LogManager uses a lock around file operations (`keylogger.py:252-255`):

```python
def write_event(self, event: KeyEvent) -> None:
    with self._lock:
        self._file.write(event.to_log_string() + '\n')
        self._file.flush()
        self._check_rotation()
```

WebhookDelivery uses a lock with a buffer swap pattern (`keylogger.py:315-324`). The key insight is that delivery happens outside the lock:

```python
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

**Why we chose it:**
The pynput callback runs in a separate thread from our main program. Without locks, simultaneous file writes could corrupt the log file. Similarly, the event buffer could have race conditions if accessed from multiple threads. The buffer swap pattern in WebhookDelivery minimizes lock hold time by doing the slow network I/O outside the lock.

**Trade-offs:**
- Pros: Prevents data corruption, ensures consistency, simple to reason about (lock, access, unlock), buffer swap minimizes contention during network delivery
- Cons: Potential performance bottleneck (though keyboard events are slow enough this doesn't matter), risk of deadlock if locks acquired in wrong order (we only use one lock per component so this isn't an issue)

### Immutable Data with Dataclasses

**What it is:**
Dataclasses provide a clean syntax for creating classes that primarily store data. Making them immutable (frozen) prevents accidental modification.

**Where we use it:**
KeyEvent represents a keystroke (`keylogger.py:123-152`):

```python
@dataclass
class KeyEvent:
    timestamp: datetime
    key: str
    window_title: str | None = None
    key_type: KeyType = KeyType.CHAR
```

KeyloggerConfig stores configuration (`keylogger.py:107-120`):

```python
@dataclass
class KeyloggerConfig:
    log_dir: Path = Path.home() / ".keylogger_logs"
    log_file_prefix: str = "keylog"
    max_log_size_mb: float = 5.0
    # ... more fields
```

**Why we chose it:**
Dataclasses reduce boilerplate (no need to write `__init__`, `__repr__`, etc). Type hints make the data structure self-documenting. Immutability prevents bugs where events get modified after creation.

**Trade-offs:**
- Pros: Less code, better type safety, automatic equality comparison, clear data structure
- Cons: Slightly less flexible than regular classes, can't be modified after creation (though this is intentional)

## Layer Separation

The architecture has a clear separation between concerns:

```
┌─────────────────────────────────────────────────┐
│           Application Layer                     │
│  - Keylogger main class                         │
│  - Lifecycle management (start/stop)            │
│  - Event processing pipeline                    │
└─────────────────┬───────────────────────────────┘
                  │
┌─────────────────┴───────────────────────────────┐
│           Service Layer                         │
│  - LogManager (persistence)                     │
│  - WebhookDelivery (exfiltration)               │
│  - WindowTracker (context gathering)            │
└─────────────────┬───────────────────────────────┘
                  │
┌─────────────────┴───────────────────────────────┐
│           Data Layer                            │
│  - KeyEvent (event representation)              │
│  - KeyloggerConfig (configuration)              │
│  - KeyType (enum classification)                │
└─────────────────────────────────────────────────┘
```

### Why Layers?

Layers enable independent modification. We can swap LogManager for a database writer without touching Keylogger. We can add new exfiltration methods alongside WebhookDelivery. Testing is easier since we can mock service layer components.

### What Lives Where

**Application Layer:**
- Files: Main Keylogger class (`keylogger.py:373-533`)
- Imports: Can import from service and data layers
- Forbidden: Direct file I/O (delegates to LogManager), HTTP requests (delegates to WebhookDelivery)

**Service Layer:**
- Files: LogManager (`keylogger.py:222-296`), WebhookDelivery (`keylogger.py:298-371`), WindowTracker (`keylogger.py:155-219`)
- Imports: Can import data layer, should not import application layer
- Forbidden: Knowledge of Keylogger implementation details, accessing pynput directly

**Data Layer:**
- Files: KeyEvent (`keylogger.py:123-152`), KeyloggerConfig (`keylogger.py:107-120`), KeyType (`keylogger.py:98-104`)
- Imports: Only standard library (datetime, pathlib, enum)
- Forbidden: Business logic, I/O operations, external dependencies

## Data Models

### KeyEvent

```python
@dataclass
class KeyEvent:
    timestamp: datetime
    key: str
    window_title: str | None = None
    key_type: KeyType = KeyType.CHAR
```

**Fields explained:**
- `timestamp`: When the keystroke occurred, used for log chronology and forensics. DateTime includes timezone info via `datetime.now()`.
- `key`: String representation of the key pressed. Either a single character ("a") or a bracketed special key ("[ENTER]"). Never empty.
- `window_title`: Context about where the keystroke occurred. None if window tracking disabled or platform unsupported. Format varies by platform (Windows includes process name, macOS just app name).
- `key_type`: Classification (CHAR/SPECIAL/UNKNOWN) used to filter special keys if `log_special_keys` is False in config.

**Relationships:**
KeyEvent is created by Keylogger, consumed by LogManager and WebhookDelivery. It's the universal data structure that flows through the entire pipeline.

### KeyloggerConfig

```python
@dataclass
class KeyloggerConfig:
    log_dir: Path = Path.home() / ".keylogger_logs"
    log_file_prefix: str = "keylog"
    max_log_size_mb: float = 5.0
    webhook_url: str | None = None
    webhook_batch_size: int = 50
    toggle_key: Key = Key.f9
    enable_window_tracking: bool = True
    log_special_keys: bool = True
    window_check_interval: float = WINDOW_CHECK_INTERVAL_SECS
```

**Fields explained:**
- `log_dir`: Where log files are stored. Default `~/.keylogger_logs` is hidden on Unix. Created automatically by LogManager's `__init__`, not by KeyloggerConfig (config is a pure data container with no side effects).
- `log_file_prefix`: Prefix for log filenames. Combined with timestamp to create unique files like "keylog_20250131_143022_987654.txt".
- `max_log_size_mb`: File size limit in megabytes before rotation. 5MB default balances stealth (not too large) with minimizing file count.
- `webhook_url`: Optional remote endpoint for exfiltration. If None, only local logging occurs. Must be HTTPS for security.
- `webhook_batch_size`: Number of keystrokes to buffer before sending. Higher values reduce network noise but increase data loss risk if program crashes.
- `toggle_key`: Hotkey to pause/resume logging. Default F9 is unlikely to be pressed accidentally but easy to reach.
- `enable_window_tracking`: Whether to capture active window titles. Adds context but requires platform-specific dependencies.
- `log_special_keys`: Whether to log [SHIFT], [CTRL], etc. Set False to reduce log size and focus on printable characters.
- `window_check_interval`: How often (in seconds) to refresh the cached window title. Defaults to the WINDOW_CHECK_INTERVAL_SECS constant (0.5 seconds).

**Relationships:**
Passed to all service layer components (LogManager, WebhookDelivery, Keylogger). Centralized configuration avoids passing individual parameters.

### KeyType Enum

```python
class KeyType(Enum):
    CHAR = auto()
    SPECIAL = auto()
    UNKNOWN = auto()
```

Classifies keys for filtering and logging decisions. CHAR is printable characters (a-z, 0-9, symbols). SPECIAL is control keys (Enter, Tab, arrows). UNKNOWN is for edge cases where key classification fails.

## Security Architecture

### Threat Model

What we're protecting against:
1. **Detection by Antivirus** - AV scans for known malware signatures, behavioral patterns, and suspicious API calls. Our keylogger uses legitimate libraries (pynput) which reduces signature detection but behavioral analysis might flag keyboard hooks.
2. **Network Monitoring** - Corporate networks monitor traffic for data exfiltration. HTTPS webhook delivery encrypts content but traffic analysis could detect periodic POST requests to external domains.
3. **User Suspicion** - If log files grow too large, rotate too frequently, or create disk I/O spikes, users might investigate. Performance impact from processing every keystroke could also raise red flags.

What we're NOT protecting against (out of scope):
- Kernel-level monitoring or EDR that hooks system calls below our privilege level
- Memory forensics that scan RAM for keystroke buffers
- Hardware keyloggers or BIOS-level monitoring
- Physical access to the machine for disk forensics

### Defense Layers

Our layered security approach (from the attacker's perspective):

```
Layer 1: Execution Prevention
    ↓ (bypassed if user runs the program)
Layer 2: Behavioral Detection
    ↓ (evaded via legitimate API usage)
Layer 3: Network Monitoring
    ↓ (mitigated with HTTPS and batching)
Layer 4: Forensic Detection
    ↓ (requires active investigation)
```

**Why multiple layers?**
Defense in depth assumes each layer can be bypassed but makes detection harder. If antivirus misses us (Layer 1), network monitoring might catch exfiltration (Layer 3). If we run on a laptop that's never inspected, we persist indefinitely despite forensic detectability (Layer 4).

## Storage Strategy

### Local File Storage

**What we store:**
- Timestamped keystroke events with window context
- Plain text format for easy exfiltration and reading
- Multiple files via rotation to avoid suspiciously large files

**Why this storage:**
Files are simple, don't require external dependencies (database), and are easy to exfiltrate (just upload the directory). Plain text trades security for simplicity since this is an educational project. Production malware would encrypt logs.

**Schema design:**
```
[2025-01-31 14:30:22][Chrome - Gmail] p
[2025-01-31 14:30:22][Chrome - Gmail] a
[2025-01-31 14:30:22][Chrome - Gmail] s
[2025-01-31 14:30:22][Chrome - Gmail] s
[2025-01-31 14:30:23][Chrome - Gmail] [ENTER]
```

Each line is independent. Chronological ordering simplifies reading. Window context in brackets enables filtering by application during analysis.

### In-Memory Buffering

WebhookDelivery maintains an in-memory buffer of KeyEvent objects before batch delivery. This reduces network calls but risks data loss if the program crashes before flush. Trade-off favors stealth over completeness.

## Configuration

### Environment Variables

The project doesn't use environment variables by default. Configuration is hardcoded in `main()` (`keylogger.py:536-547`), which simply creates a `Keylogger(KeyloggerConfig())` with all defaults. This avoids dependencies on shell environment but makes it harder to change config without modifying code.

For production use, you'd add environment variable support:
```python
config = KeyloggerConfig(
    webhook_url=os.getenv("KEYLOGGER_WEBHOOK_URL"),
    max_log_size_mb=float(os.getenv("KEYLOGGER_MAX_SIZE_MB", "5.0"))
)
```

### Configuration Strategy

**Development:**
Hardcoded config with webhook disabled, local logging to visible directory for easy testing. Toggle key enabled for quick pause during debugging.

**Production:**
Would load config from encrypted file or remote C2 server. Log directory hidden (`.keylogger_logs` with leading dot on Unix, `AppData/Local` on Windows). Webhook enabled with obfuscated domain. Toggle key disabled to prevent accidental discovery.

## Performance Considerations

### Bottlenecks

Where this system gets slow under load:
1. **File I/O on every keystroke** - Writing to disk for each event creates I/O contention. LogManager calls `self._file.write()` followed by `self._file.flush()` on every keystroke, bypassing any OS-level write buffering. High keystroke rates (fast typist or gaming) could still cause lag.
2. **Window title lookups** - Platform APIs (win32gui, NSWorkspace, xdotool subprocess) have latency. We cache window title for `config.window_check_interval` seconds (default 0.5, `keylogger.py:400`) to reduce API calls from thousands per second to ~2 per second.
3. **Webhook HTTP requests** - Network latency blocks the callback thread during POST. We use timeout=WEBHOOK_TIMEOUT_SECS (5 seconds, `keylogger.py:346`) to avoid hanging indefinitely but 5 seconds is still noticeable if batches send frequently.

### Optimizations

What we did to make it faster:
- **Window title caching**: Only update every `config.window_check_interval` seconds (default 0.5) instead of every keystroke. Reduces API calls by 99%+ for typical typing speeds. Interval is configurable via KeyloggerConfig.
- **Batched webhook delivery**: Sending 50 events in one request instead of 50 individual requests reduces network overhead from ~1 second per keystroke to ~1 second per 50 keystrokes.
- **Buffer swap pattern**: WebhookDelivery swaps the event buffer under the lock and delivers outside the lock. The lock is only held for the brief list swap, not during the slow HTTP POST.
- **Lock-free reads in hot path**: The `_on_press` callback doesn't acquire locks during key processing, only when writing to shared resources. Reduces contention.

### Scalability

**Vertical scaling:**
Adding CPU/RAM helps with faster file I/O and larger webhook batches. Disk speed matters more than CPU since we're I/O bound. 16GB RAM is overkill, this runs fine on 512MB.

**Horizontal scaling:**
Doesn't apply. This runs on a single victim machine. You can't distribute one keylogger across multiple hosts (though you could deploy copies to multiple victims).

## Design Decisions

### Decision 1: Plain Text Logs via Direct File I/O

**What we chose:**
Plain text logs written with direct file I/O (`open()`, `write()`, `flush()`).

**Alternatives considered:**
- Python's `logging` module with FileHandler: Adds unnecessary abstraction and log-level formatting overhead for what is ultimately plain text output
- Encrypted logs with AES: Harder to detect via keyword scans but requires key management and decryption on exfiltration
- Database storage (SQLite): Enables querying and indexing but adds dependency and creates obvious .db file

**Trade-offs:**
Direct file I/O is the simplest approach. We control the exact format, there's no log-level prefix or formatter to configure, and the file handle is managed explicitly with `close()` for clean shutdown. You can open log files in any text editor and immediately see captured keystrokes. This trades stealth (forensics can easily find passwords in plaintext) for learning value. Production malware would encrypt logs.

### Decision 2: Dataclasses vs Regular Classes

**What we chose:**
Dataclasses for KeyEvent and KeyloggerConfig.

**Alternatives considered:**
- Regular classes with manual `__init__`: More flexible but verbose
- Named tuples: Immutable and simple but no type hints or default values
- dictionaries: Most flexible but no type safety

**Trade-offs:**
Dataclasses give us type hints, default values, automatic `__repr__`, and less boilerplate. This makes the code self-documenting and safer. We give up some flexibility (can't dynamically add fields) but gain clarity.

### Decision 3: pynput vs Platform-Specific Hooks

**What we chose:**
pynput library for cross-platform keyboard capture.

**Alternatives considered:**
- SetWindowsHookEx on Windows: Lower level, harder to detect, but Windows-only
- Quartz Events on macOS: More control, requires elevated permissions
- X11 XRecord on Linux: Works on older systems, doesn't support Wayland

**Trade-offs:**
pynput abstracts platform differences and requires minimal code. We give up some control and performance (pynput adds overhead) but gain portability. Single codebase runs on all major platforms.

## Deployment Architecture

This is a standalone Python script, not a service. Deployment depends on attack scenario:

**Persistence (Windows):**
Registry Run key: `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run`
Scheduled Task: `schtasks /create /tn "SystemUpdate" /tr "python keylogger.py" /sc onlogon`

**Persistence (macOS):**
LaunchAgent: `~/Library/LaunchAgents/com.example.keylogger.plist`

**Persistence (Linux):**
Systemd user service: `~/.config/systemd/user/keylogger.service`
Cron: `@reboot python /path/to/keylogger.py`

Deployment requires initial access (phishing, USB drop, etc) and depends on whether victim has Python installed or if you compile to executable with PyInstaller.

## Error Handling Strategy

### Error Types

1. **Import failures (missing dependencies)** - pynput import failure raises `ImportError("pynput is required: uv add pynput")` at module level (`keylogger.py:42-46`), halting execution immediately with a clear message. Platform-specific imports (win32gui, NSWorkspace) are caught and set to None (`keylogger.py:57-68`), allowing graceful degradation on unsupported platforms.
2. **Webhook delivery failures** - Caught and logged via `logging.error()` with traceback (`keylogger.py:353-357`), doesn't crash the keylogger. The buffer swap pattern means failed events are already removed from the buffer, so they won't be retried.
3. **File I/O errors during rotation** - `_check_rotation()` handles `FileNotFoundError` (`keylogger.py:263-265`) by immediately rotating to a new file if the current log was deleted externally.
4. **Webhook non-OK responses** - Checked via `response.ok` (`keylogger.py:348`), logged as a warning with the status code but doesn't crash.

### Recovery Mechanisms

**Webhook failure scenario:**
- Detection: `requests.post()` raises exception or `response.ok` is False
- Response: Log warning/error message, continue operation
- Recovery: Future batches are independent; the keylogger continues capturing and delivering new batches

**File rotation failure scenario:**
- Detection: `FileNotFoundError` when calling `Path.stat()` on current log
- Response: Immediately rotate to a new file
- Recovery: New file handle is opened, logging continues uninterrupted

**File handle cleanup:**
- `stop()` calls `self.log_manager.close()` (`keylogger.py:529`) which closes the underlying file handle under the lock, ensuring no writes are in flight during shutdown

## Extensibility

### Where to Add Features

Want to add screenshot capture on certain keywords? Here's where it goes:

1. Create new `ScreenshotCapture` class in the service layer (similar to WebhookDelivery)
2. Modify `Keylogger._on_press()` to check for trigger keywords (`keylogger.py:428-458`)
3. Call `screenshot.capture()` when keyword detected (like "password" or "credit card")
4. Store screenshots alongside logs or bundle in webhook payload

Want to add clipboard monitoring?

1. Create `ClipboardMonitor` class that polls clipboard with `pyperclip`
2. Start monitoring thread in `Keylogger.start()` (`keylogger.py:479-514`)
3. Log clipboard changes to same LogManager instance

## Limitations

Current architectural limitations:
1. **Single-threaded event processing** - Keystrokes processed sequentially. Under extreme load (gaming, rapid macros), events could queue up. Fix: Process events in thread pool.
2. **No encryption** - Logs and webhooks use plaintext (HTTPS encrypts transport but payload is unencrypted JSON). Fix: Add AES encryption with key derivation.
3. **No persistence** - Program doesn't restart after reboot. Fix: Add platform-specific autostart mechanisms.
4. **No stealth** - Process shows in task manager with obvious name "python keylogger.py". Fix: Compile to executable with PyInstaller and rename to "svchost.exe" or similar.

These are not bugs, they're conscious trade-offs to keep the educational project simple. Fixing them would require platform-specific code that obscures the core concepts.

## Comparison to Similar Systems

### Commercial Keyloggers (Spyrix, Revealer Keylogger)

How we're different:
- Commercial tools are compiled executables with obfuscation and anti-detection, we're readable Python source
- They include screenshot capture, webcam access, and full system monitoring, we focus on keystroke capture
- They use kernel drivers for stealth, we use user-space libraries that are easier to detect

Why we made different choices:
This is an educational project to teach concepts, not production malware. Readable source code and simple architecture help learning. Commercial tools prioritize stealth, we prioritize clarity.

### Open Source Alternatives (PyLogger, Python-Keylogger)

How we're different:
- Many open source keyloggers lack tests, we include `test_keylogger.py` with 46 pytest tests across 579 lines
- We use modern Python (dataclasses, type hints, enum) instead of legacy Python 2 code
- Our architecture separates concerns (LogManager, WebhookDelivery) instead of monolithic main function

Why we made different choices:
Clean architecture makes the code easier to understand and extend. Type hints catch bugs early. Tests verify components work correctly.

## Key Files Reference

Quick map of where to find things:

- `keylogger.py:70-73` - Module-level constants (BYTES_PER_MB, WEBHOOK_TIMEOUT_SECS, WINDOW_CHECK_INTERVAL_SECS, LISTENER_JOIN_TIMEOUT_SECS)
- `keylogger.py:75-95` - SPECIAL_KEYS dict (module-level constant mapping Key to display labels)
- `keylogger.py:98-104` - KeyType enum (keystroke classification)
- `keylogger.py:107-120` - KeyloggerConfig dataclass (all configuration options, pure data container)
- `keylogger.py:123-152` - KeyEvent dataclass (event structure)
- `keylogger.py:155-219` - WindowTracker class (platform-specific window detection)
- `keylogger.py:222-296` - LogManager class (direct file I/O writing and rotation)
- `keylogger.py:298-371` - WebhookDelivery class (remote exfiltration with buffer swap pattern)
- `keylogger.py:373-533` - Keylogger main class (orchestration)
- `keylogger.py:406-426` - _process_key() method (key classification using module-level SPECIAL_KEYS)
- `keylogger.py:428-458` - _on_press() callback (event handler)
- `keylogger.py:460-477` - _toggle_logging() (dynamic toggle key name via config)
- `keylogger.py:516-533` - stop() method (calls log_manager.close() for file handle cleanup)
- `keylogger.py:536-547` - main() (simplified to Keylogger(KeyloggerConfig()))
- `test_keylogger.py` - 46 pytest tests across 579 lines

## Next Steps

Now that you understand the architecture:
1. Read [03-IMPLEMENTATION.md](./03-IMPLEMENTATION.md) for detailed code walkthrough and implementation patterns
2. Try modifying WindowTracker to cache window titles longer (10 seconds instead of 0.5) and observe the performance impact
3. Experiment with changing `webhook_batch_size` from 50 to 5 and monitor network traffic to see the difference in request frequency
