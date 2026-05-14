<!-- © AngelaMos | 2026 | 04-CHALLENGES.md -->

# Extension Challenges

These challenges extend the C2 beacon project with real features found in production command-and-control frameworks. They are ordered by difficulty, and each one references actual files in this project. Read the referenced code before you start. The hints point you in the right direction without giving you the full solution.

Each challenge references real functions, real class names, and real file paths. If a hint says "look at `COMMAND_HANDLERS` in `beacon.py`," go read that dictionary. The code is the source of truth.

---

## Easy Challenges

---

### Challenge 1: Add a `pwd` Command

**What to build:** A new command that returns the beacon's current working directory to the operator.

**Why it matters:** Every real C2 framework supports directory awareness. Cobalt Strike, Sliver, and Metasploit all have `pwd` and `cd` commands because operators need to know where file operations will land. Without `pwd`, if you run `download notes.txt`, you have no idea which `notes.txt` you are grabbing.

**What you will learn:**
- How new commands propagate through the entire stack (beacon handler, backend enum, frontend types, UI)
- The full lifecycle of a command: frontend submission, WebSocket relay, beacon execution, result return

**Where to start reading:**

The command dispatch system is in `beacon/beacon.py`. Look at the `COMMAND_HANDLERS` dictionary at line 419. Every command maps a string key to an async handler function. The `dispatch` function at line 433 does the routing: it looks up the command string in the dictionary and calls the matching handler.

On the backend, `backend/app/core/models.py:12-26` defines `CommandType` as a `StrEnum`. Every supported command must be listed here or the Pydantic validation at `backend/app/ops/router.py:60` will reject it.

On the frontend, `frontend/src/core/types.ts:8-19` mirrors the enum as a Zod schema. The session page at `frontend/src/pages/session/index.tsx:19-30` has a `COMMANDS` array that controls which commands the input parser accepts.

**Hints:**

1. The beacon handler is trivial. Python's `os.getcwd()` returns the current working directory as a string. Your handler should follow the same return pattern as the other handlers: `{"output": ..., "error": None}`.

2. You need to touch four files in this order:
   - Add `PWD = "pwd"` to the `CommandType` enum in `backend/app/core/models.py`
   - Add `'pwd'` to the Zod enum array in `frontend/src/core/types.ts`
   - Add `'pwd'` to the `COMMANDS` array in `frontend/src/pages/session/index.tsx`
   - Add the handler function and its entry in `COMMAND_HANDLERS` in `beacon/beacon.py`

3. Look at `handle_sysinfo` at `beacon/beacon.py:153` for the pattern. Your handler will be much simpler, about 3 lines.

**Files to modify:**
- `beacon/beacon.py`
- `backend/app/core/models.py`
- `frontend/src/core/types.ts`
- `frontend/src/pages/session/index.tsx`

**How to test:**
- Start the full stack with Docker
- Connect a beacon
- Type `pwd` in the session terminal
- Verify you get back a directory path like `/home/yoshi/dev/...`

---

### Challenge 2: Add Beacon Uptime Display

**What to build:** Show how long each beacon has been connected as a new column in the dashboard table. Display it as a human-readable duration like "2h 15m" or "3d 6h".

**Why it matters:** Operators in real C2 engagements need to quickly assess which beacons are fresh versus long-running. A beacon that has been alive for 5 days is more valuable than one that connected 30 seconds ago, because it has survived reboots, AV scans, and network changes. Uptime at a glance changes how operators prioritize targets.

**What you will learn:**
- Reading from existing data models without modifying the backend
- Date arithmetic in JavaScript
- Extending React table components

**Where to start reading:**

The `BeaconRecord` model already has everything you need. Look at `frontend/src/core/types.ts:22-34`. The `first_seen` field is an ISO 8601 timestamp string set when the beacon first registered. The `last_seen` field updates on every heartbeat.

The dashboard table is in `frontend/src/pages/dashboard/index.tsx`. The `BeaconRow` component at line 43 renders one row per beacon. The table headers are at lines 120-128. There is already a `formatRelativeTime` function at line 14 that converts ISO timestamps to relative strings like "5s ago" or "2h ago". You can use a similar approach, or compute `Date.now() - new Date(beacon.first_seen).getTime()` to get the uptime in milliseconds.

The dashboard already has a 1-second tick interval at lines 95-98 that forces re-renders, so your uptime display will update automatically every second.

**Hints:**

1. The uptime is the difference between now and `first_seen`. Subtraction gives you milliseconds. Convert to hours and minutes for display.

2. Add a new `<th>Uptime</th>` in the table header and a matching `<td>` in `BeaconRow`. Put it before the "Last Seen" column.

3. Write a `formatUptime` function that takes an ISO string and returns something like "4h 22m" or "1d 3h". Do not overthink it: divide milliseconds by the appropriate constants (1000 for seconds, 60 for minutes, etc.).

**Files to modify:**
- `frontend/src/pages/dashboard/index.tsx`

**How to test:**
- Start the stack, connect a beacon
- Verify the uptime column shows "0s" or "1s" initially
- Wait a few minutes and verify it updates
- Refresh the page and verify it still shows the correct uptime (because `first_seen` is persisted in SQLite)

---

### Challenge 3: Add a `clear` Terminal Command

**What to build:** A client-side `clear` command that empties the terminal output in the session page, like running `clear` in a real terminal.

**Why it matters:** When you are running dozens of commands during an engagement, the terminal fills up fast. Operators need to clear their view without losing the ability to run new commands. This is also a good exercise in understanding which commands are client-side-only versus which ones travel to the beacon.

**What you will learn:**
- Client-side command interception (handling commands before they hit the network)
- The difference between client-side and server-side command processing
- React state manipulation

**Where to start reading:**

The `handleSubmit` function at `frontend/src/pages/session/index.tsx:174` is where every command starts. It calls `parseInput` (line 39) to validate the command, then calls `handleSend` (line 164) which adds a terminal entry and sends the task over the WebSocket via `sendTask`.

The terminal output is stored in the `entries` state array at line 145. Calling `setEntries([])` clears all terminal entries.

The `parseInput` function at line 39 checks if the typed command is in the `COMMANDS` array. If the command is not found, it returns `null` and `handleSubmit` does nothing.

**Hints:**

1. `clear` should NOT be added to the `COMMANDS` array, the `CommandType` enum, or the backend models. It never leaves the frontend.

2. Intercept `clear` inside `handleSubmit` BEFORE the `parseInput` call. Check if `input.trim() === 'clear'`, and if so, call `setEntries([])`, clear the input, and return early.

3. You might also want to add `clear` as a recognized command in the autocomplete suggestions. The `handleInputChange` function at line 223 filters the `COMMANDS` array for suggestions. You could create a separate `CLIENT_COMMANDS` array or just hardcode the check.

**Files to modify:**
- `frontend/src/pages/session/index.tsx`

**How to test:**
- Open a session, run a few commands
- Type `clear` and press Enter
- Verify the terminal empties
- Run new commands and verify they appear normally
- Verify no network request was sent (check the WebSocket frames in DevTools)

---

### Challenge 4: Add Connection Count to Header

**What to build:** Display the number of connected operators somewhere in the dashboard header. Something like "2 operators connected" next to the beacon count.

**Why it matters:** In a team engagement, multiple operators may be connected to the same C2 server. Knowing how many people are active helps coordinate. If you see "0 operators" while you expected your teammate to be online, something is wrong, either their connection dropped or something is intercepting traffic.

**What you will learn:**
- Adding REST endpoints to the FastAPI backend
- Fetching data from the backend in React components
- The relationship between the OpsManager and the operator WebSocket

**Where to start reading:**

The `OpsManager` class at `backend/app/ops/manager.py:15` already tracks connections. The `connection_count` property at line 56 returns `len(self._connections)`. The operator REST router at `backend/app/ops/router.py` has endpoints starting at line 94.

The dashboard component at `frontend/src/pages/dashboard/index.tsx:100` renders a header section at lines 103-112 that already shows the beacon count.

**Hints:**

1. The simplest approach: add a new REST endpoint to `backend/app/ops/router.py`. Something like `GET /api/operators/count` that returns `{"count": ops_manager.connection_count}`. Access the ops_manager from `request.app.state.ops_manager`.

2. On the frontend, fetch this endpoint with a `useEffect` on mount. Store the result in local state. Display it next to the existing beacon count in the header.

3. An alternative approach that avoids polling: include the operator count in the initial `beacon_list` WebSocket payload at `backend/app/ops/router.py:46-49`. Add an `operator_count` field. This way it arrives immediately on connect without an extra HTTP request. But it will not update in real time unless you also broadcast count changes.

4. Consider which approach gives better real-time accuracy. The REST endpoint only updates when the user refreshes or you poll. The WebSocket approach updates whenever you broadcast it. A hybrid approach works well: send the count on initial connect, and broadcast updates whenever an operator connects or disconnects.

**Files to modify:**
- `backend/app/ops/router.py`
- `frontend/src/pages/dashboard/index.tsx`
- Optionally: `frontend/src/core/ws.ts` and `frontend/src/core/types.ts` (if using the WebSocket approach)

---

## Intermediate Challenges

---

### Challenge 5: Add Operator Authentication

**What to build:** Require a password before allowing WebSocket connections from operators. If the password is wrong, close the connection immediately with a 4001 status code.

**Why it matters:** Right now, anyone who can reach the C2 server's WebSocket endpoint can connect as an operator and control every beacon. In a real engagement, this means a defender who discovers the C2 server can send `shell rm -rf /` to every beacon or simply watch all task results. Every production C2 framework has operator authentication. Cobalt Strike uses team passwords. Sliver uses mutual TLS with operator certificates.

**What you will learn:**
- WebSocket authentication patterns
- Environment variable-based configuration
- Securing a protocol that was designed without auth

**Where to start reading:**

The operator WebSocket handler is at `backend/app/ops/router.py:25-91`. The connection flow is: `ops_manager.connect(ws)` accepts the WebSocket at line 34, then immediately sends the beacon list at lines 36-49, then enters a message receive loop at line 51.

The `Settings` class at `backend/app/config.py:17` loads configuration from environment variables using Pydantic settings. The `XOR_KEY` field at line 41 shows the pattern for adding new config values with defaults.

The frontend WebSocket connection is established at `frontend/src/core/ws.ts:166-167`. The `connect` function creates a new `WebSocket` and sets up event handlers. Currently, no authentication data is sent on connect.

**Hints:**

1. Add an `AUTH_KEY` field to the `Settings` class in `backend/app/config.py`. Give it a default value for development, like `"operator-default-key"`. Load it from the `AUTH_KEY` environment variable.

2. In the operator WebSocket handler at `router.py:25`, BEFORE calling `ops_manager.connect(ws)`, accept the connection manually with `await ws.accept()`, then wait for the first message. If it matches `settings.AUTH_KEY`, proceed normally. If not, call `await ws.close(code=4001, reason="Unauthorized")` and return.

3. On the frontend, modify the `connect` function in `ws.ts`. In the `ws.onopen` callback (line 170), send the auth key as the first message: `ws.send(JSON.stringify({ type: "auth", key: "..." }))`. You will need the key available in the frontend, either hardcoded for development, or loaded from a login form, or passed via an environment variable using Vite's `import.meta.env`.

4. You will also need to adjust `ops_manager.connect()` at `manager.py:25`. Currently it calls `await ws.accept()`. If you manually accept in the router before auth, the manager should skip the accept call. Alternatively, restructure so the manager does the accepting and auth checking.

5. Watch out for the message loop at `router.py:51`. After auth, the first "real" message should be a `submit_task`, not the auth message. Make sure you do not accidentally interpret the auth message as a task submission.

**Files to modify:**
- `backend/app/config.py`
- `backend/app/ops/router.py`
- `frontend/src/core/ws.ts`

**How to test:**
- Set `AUTH_KEY=my-secret-key` in your `.env` file
- Update the frontend to send this key on connect
- Start the stack and verify the dashboard loads normally
- Change the frontend key to a wrong value and verify the WebSocket closes with 4001
- Check server logs for the unauthorized attempt

---

### Challenge 6: Add More Quick Action Buttons

**What to build:** Expand the quick actions panel on the session page with additional buttons. Consider `whoami`, `uname -a`, `id`, `hostname`, and network commands.

**Why it matters:** Quick actions speed up common reconnaissance tasks during an engagement. Real C2 operators run the same handful of commands on every new beacon to orient themselves: who am I, what system is this, what network am I on. Having one-click buttons for these beats typing them every time.

**What you will learn:**
- How quick actions map to existing command types
- Building shell commands that get sent through the `shell` command type
- Extending React component interfaces

**Where to start reading:**

The `QuickActions` component is at `frontend/src/pages/session/index.tsx:55-88`. It renders three buttons for `sysinfo`, `proclist`, and `screenshot`. Each button calls `onSend` with a `CommandType`. The `onSend` prop comes from `handleSend` at line 164, which accepts a `CommandType` and optional `args`.

Notice that `sysinfo`, `proclist`, and `screenshot` are their own command types, so the buttons call `onSend('sysinfo')` with no args. But for shell commands, you need to call `handleSend` with both the command type and arguments, like `handleSend('shell', 'whoami')`.

**Hints:**

1. The `QuickActions` component currently takes `onSend: (cmd: CommandType) => void`. You need to change this to accept args too: `onSend: (cmd: CommandType, args?: string) => void`. This matches the signature of `handleSend` at line 164, which already accepts optional args.

2. Add new buttons that call `onSend('shell', 'whoami')`, `onSend('shell', 'uname -a')`, `onSend('shell', 'id')`, etc.

3. Consider grouping the buttons. You could create sections: "System Info" for sysinfo/proclist, "Quick Recon" for shell commands, "Collection" for screenshot. Use a heading or visual separator.

4. You could also add buttons for `keylog_start`, `keylog_stop`, and `sleep`. The sleep button might want to prompt for an interval, but start simple with a fixed value.

**Files to modify:**
- `frontend/src/pages/session/index.tsx`

**How to test:**
- Open a session with an active beacon
- Click each new quick action button
- Verify the correct command and args appear in the terminal
- Verify the beacon returns results for each

---

### Challenge 7: Task History Persistence

**What to build:** When you navigate away from a session page and come back, reload the previous task history from the server so the terminal shows past commands and results.

**Why it matters:** Right now, the terminal entries live in React component state. Navigate away and they vanish. In a real engagement that lasts hours or days, operators switch between beacons constantly. Losing terminal history means losing context about what has already been run, leading to redundant commands or missed results.

**What you will learn:**
- Fetching historical data from REST APIs on component mount
- Mapping database records to UI state
- The relationship between the WebSocket (real-time) and REST (historical) data paths

**Where to start reading:**

The REST endpoint already exists. Look at `backend/app/ops/router.py:128-137`. The `GET /beacons/{beacon_id}/tasks` endpoint calls `task_manager.get_history(beacon_id, db)` which is implemented at `backend/app/beacon/tasking.py:93-116`. This function joins `tasks` with `task_results` and returns rows with columns: `id`, `command`, `args`, `status`, `created_at`, `completed_at`, `output`, `error`.

The session page at `frontend/src/pages/session/index.tsx:138` has the `Component` function. The `entries` state at line 145 is `TerminalEntry[]` where each entry has `command`, `args`, `result`, and `taskId`.

The `TerminalEntry` interface is at line 32. The `result` field is `TaskResult | null`, and `TaskResult` (from `types.ts:47-54`) has `id`, `task_id`, `output`, `error`, and `created_at`.

**Hints:**

1. Add a `useEffect` in the `Component` function that fetches `/api/beacons/${id}/tasks` on mount. Parse the response into `TerminalEntry[]` objects and call `setEntries(...)` with the result.

2. You need to map the REST response format to `TerminalEntry`. The REST response has `command`, `args`, `output`, `error`, and `id` (the task ID). Build each entry like:
   ```
   {
     command: row.command,
     args: row.args,
     result: row.output || row.error ? { id: "...", task_id: row.id, output: row.output, error: row.error, created_at: row.created_at } : null,
     taskId: row.id,
   }
   ```

3. The history comes back in `ORDER BY created_at DESC` (see `tasking.py:113`), so you will want to reverse it for chronological display in the terminal.

4. Be careful not to duplicate entries. If a task result arrives via WebSocket while you are also loading history from REST, you could end up with the same entry twice. Consider deduplicating by `taskId` or only loading history if `entries` is empty.

**Files to modify:**
- `frontend/src/pages/session/index.tsx`

**How to test:**
- Open a session, run several commands, wait for results
- Navigate back to the dashboard
- Click the same beacon again to re-enter the session
- Verify the previous commands and results appear in the terminal
- Run a new command and verify it appends correctly after the historical entries

---

### Challenge 8: Add AES-256 Encryption

**What to build:** Replace the XOR encoding with AES-256-GCM encryption for the beacon-to-server communication channel.

**Why it matters:** XOR encoding is trivially reversible. Anyone who captures the traffic and discovers the key (which is a static string from an environment variable) can decode every message. Even without the key, XOR encoding is vulnerable to known-plaintext attacks. If an attacker knows the beacon sends a `HEARTBEAT` message every few seconds, they can XOR the known plaintext against the ciphertext to recover the key.

AES-256-GCM provides authenticated encryption: confidentiality (attackers cannot read the message), integrity (attackers cannot modify the message without detection), and authentication (the decryptor can verify the message came from someone with the key).

MITRE ATT&CK reference: T1573.001 (Encrypted Channel: Symmetric Cryptography).

**What you will learn:**
- AES-GCM symmetric encryption with random IVs
- Key derivation from passwords using PBKDF2 or HKDF
- The difference between encoding (XOR, Base64) and encryption (AES-GCM)
- Updating both sides of a communication protocol simultaneously

**Where to start reading:**

The server-side encoding is at `backend/app/core/encoding.py`. The `encode` function at line 16 does `UTF-8 -> XOR -> Base64`. The `decode` function at line 24 reverses it. These are called by `backend/app/core/protocol.py:37-59` in the `pack` and `unpack` functions.

The beacon-side encoding is at `beacon/beacon.py:56-78`. The `xor_bytes`, `encode`, and `decode` functions mirror the server side exactly.

The XOR key comes from `backend/app/config.py:41-44` (`XOR_KEY` setting) and `beacon/beacon.py:40-41` (`C2_XOR_KEY` environment variable). Both default to `"c2-beacon-default-key-change-me"`.

**Hints:**

1. Use Python's `cryptography` library. Specifically, `cryptography.hazmat.primitives.ciphers.aead.AESGCM`. This gives you a clean API: `aesgcm.encrypt(nonce, plaintext, associated_data)` and `aesgcm.decrypt(nonce, ciphertext, associated_data)`.

2. AES-256 requires a 32-byte key. The current XOR key is a human-readable string. Derive a proper 256-bit key from it using HKDF or PBKDF2:
   ```python
   from cryptography.hazmat.primitives.kdf.hkdf import HKDF
   from cryptography.hazmat.primitives import hashes
   key = HKDF(
       algorithm=hashes.SHA256(),
       length=32,
       salt=None,
       info=b"c2-beacon-aes",
   ).derive(password.encode("utf-8"))
   ```

3. Each message needs a unique 12-byte nonce (IV). Generate it with `os.urandom(12)`. Prepend it to the ciphertext so the receiver can extract it. The final format is: `base64(nonce + ciphertext + auth_tag)`.

4. You need to update both `encoding.py` (server) and `beacon.py` (beacon) in lockstep. If one side upgrades to AES while the other still uses XOR, they cannot communicate.

5. The `protocol.py` functions `pack` and `unpack` do not need structural changes. They call `encode` and `decode`. If you change what those functions do internally, the protocol layer stays the same.

6. Write a test. The existing tests at `backend/tests/test_encoding.py` validate the XOR encode/decode round trip. Update them for AES-GCM.

**Files to modify:**
- `backend/app/core/encoding.py`
- `beacon/beacon.py`
- `backend/tests/test_encoding.py`

---

## Advanced Challenges

---

### Challenge 9: Multi-Operator Support with Roles

**What to build:** Add role-based access control where operators are either "admin" or "viewer." Admins can send commands to beacons. Viewers can watch the dashboard and see results in real time, but cannot submit tasks.

**Why it matters:** During a red team engagement, the operator who controls beacons is not always the only person watching. Team leads, report writers, and other operators may want to observe activity without the risk of accidentally running commands. Cobalt Strike has this exact feature: operators can be given "read-only" access to a team server.

**What you will learn:**
- Role-based authorization in WebSocket connections
- Server-side message filtering
- Frontend conditional rendering based on permissions

**Where to start reading:**

The `OpsManager` at `backend/app/ops/manager.py:15` stores connections as a plain `set[WebSocket]`. It has no concept of who each connection belongs to or what they are allowed to do.

The operator WebSocket handler at `backend/app/ops/router.py:51-77` processes all incoming messages the same way. The `submit_task` handler at line 55 does not check any permissions.

**Hints:**

1. Change the `OpsManager._connections` from `set[WebSocket]` to `dict[WebSocket, str]` where the value is the role ("admin" or "viewer").

2. When an operator connects, have them send a role claim in their first message (or as part of an auth message if you completed Challenge 5). Store the role in the connections dict.

3. In the `operator_websocket` handler at `router.py:55`, before processing a `submit_task` message, check the operator's role. If they are a viewer, send back an error message instead of submitting the task.

4. On the frontend, store the operator's role in the Zustand store. Use it to conditionally disable the command input and quick action buttons for viewers. Disable the buttons visually (grayed out, `disabled` attribute) so viewers can see what is available but cannot interact.

5. The `broadcast` method at `manager.py:40` should continue to send events to all operators regardless of role. Viewers need to see beacon connections, heartbeats, and task results.

**Files to modify:**
- `backend/app/ops/manager.py`
- `backend/app/ops/router.py`
- `frontend/src/core/ws.ts`
- `frontend/src/pages/session/index.tsx`

---

### Challenge 10: Beacon Staging

**What to build:** A two-stage deployment where a small stager script downloads and executes the full beacon payload from the C2 server at runtime. The stager is just a few lines of Python. The full beacon code lives on the server and is served on demand.

**Why it matters:** Real C2 frameworks almost always use stagers. The reason is operational security. A tiny stager (10-20 lines) is harder for antivirus to detect than a full beacon (500+ lines with imports like `psutil`, `mss`, and `pynput`). The stager downloads the payload into memory, so the full beacon code never touches disk, which defeats file-based scanning.

MITRE ATT&CK references: T1059.006 (Command and Scripting Interpreter: Python), T1105 (Ingress Tool Transfer).

**What you will learn:**
- Staged payload delivery
- In-memory code execution with `exec()`
- Serving code payloads from the C2 server
- The security tradeoffs of stagers vs. stageless payloads

**Where to start reading:**

The current beacon at `beacon/beacon.py` is a standalone script. It imports its dependencies at the top and runs `asyncio.run(main())` at line 513. Everything is self-contained.

The backend app is assembled in `backend/app/__init__.py` (or `__main__.py`). REST endpoints are mounted through the router files. Look at how `rest_router` is used in `backend/app/ops/router.py:22` for the pattern.

**Hints:**

1. Add a new REST endpoint to the backend: `GET /api/stage`. This endpoint reads the `beacon/beacon.py` file and returns its contents as plain text. You will need to configure the path to the beacon file (an environment variable or a settings field).

2. The stager is a small Python script that does three things:
   - Fetches the payload from the C2 server via HTTP
   - Optionally verifies a hash or signature to prevent tampering
   - Calls `exec()` to run the payload in memory

3. Keep the stager as small as possible. It should use only standard library modules (`urllib.request`, `ssl`). No `pip install` required. The smaller the stager, the harder it is to detect.

4. Consider encoding or encrypting the payload in transit. The stager could XOR-decode the payload before executing it. This adds a thin layer of obfuscation, though a determined analyst will still reverse it.

5. Think about error handling. If the C2 server is down, the stager should retry with exponential backoff, similar to the beacon's reconnect logic at `beacon.py:460-510`.

6. Security concern: `exec()` runs arbitrary code. The stager should validate that the payload came from the real C2 server, not from a man-in-the-middle. Use HTTPS for the download, or implement a shared secret that the stager uses to verify the payload.

**Files to modify:**
- New REST endpoint in `backend/app/ops/router.py` (or a new router file)
- New stager script (a separate small Python file)
- Optionally: `backend/app/config.py` for staging configuration

---

### Challenge 11: Build a Detection Tool

**What to build:** A network monitoring script that detects our beacon's traffic patterns. This script sits on the defender's side and watches for signs of C2 communication.

**Why it matters:** Building the detection tool for your own C2 framework teaches you both offense and defense simultaneously. You will understand why certain traffic patterns are suspicious and how defenders actually catch C2 beacons in the wild. This is the kind of thinking that separates script kiddies from security professionals.

This challenge also validates your C2 design. If your detection tool can catch the beacon easily, you know the beacon's OPSEC is weak.

**What you will learn:**
- Network traffic analysis with Python
- Behavioral detection (finding patterns, not signatures)
- How IDS/IPS systems like Snort and Suricata work at a conceptual level
- The defender's perspective on C2 traffic

**Where to start reading:**

Study the beacon's communication patterns by reading `beacon/beacon.py`:
- The beacon connects via WebSocket to a fixed URL (line 38): `ws://localhost:8000/ws/beacon`
- It sends a `REGISTER` message immediately on connect (line 468)
- It sends `HEARTBEAT` messages on a regular interval (line 443-453) with jitter (line 97-102)
- The heartbeat interval defaults to 3 seconds with 30% jitter (lines 42-43)
- All messages are XOR-encoded then Base64-encoded (lines 62-78)

These patterns are detectable:
- Regular periodic WebSocket connections to the same endpoint
- Base64-encoded payloads of similar sizes (heartbeats are always roughly the same length)
- A fixed WebSocket upgrade path (`/ws/beacon`)

**Hints:**

1. Use `scapy` or `pyshark` to capture network traffic. Start simple: capture all TCP traffic on the C2 server's port (default 8000) and look for WebSocket upgrade requests.

2. Detect the heartbeat rhythm. Record the timestamps of consecutive messages from the same source IP. If they arrive at a regular interval (plus or minus the jitter), flag it as suspicious. A function that computes the standard deviation of inter-message intervals will reveal the regularity.

3. Look at message sizes. Heartbeat messages are always the same plaintext length, and XOR does not change the length, so the Base64-encoded output will be the same length every time. If you see many messages of identical size from the same source, that is a strong C2 indicator.

4. Check for the WebSocket upgrade path. A GET request to `/ws/beacon` is a dead giveaway. In a real engagement, the operator would change this to something innocuous like `/api/v2/health`. For this challenge, detect the default path.

5. Consider writing Snort or Suricata rules instead of (or in addition to) a Python script. A Snort rule that matches the WebSocket upgrade to `/ws/beacon` is a one-liner.

**Files to modify:**
- New Python script (e.g., `tools/detect_beacon.py`)

---

### Challenge 12: Add a DNS-Based C2 Channel

**What to build:** An alternative transport layer where the beacon communicates through DNS TXT record queries instead of WebSockets. The beacon encodes commands and results as DNS queries and responses.

**Why it matters:** WebSocket connections to unusual endpoints are relatively easy to detect and block. DNS traffic, on the other hand, is allowed through almost every firewall because blocking DNS breaks everything. DNS-based C2 is used by sophisticated threat actors precisely because DNS is so permissive. Tools like `dnscat2`, `iodine`, and Cobalt Strike's DNS beacon all exploit this.

MITRE ATT&CK reference: T1071.004 (Application Layer Protocol: DNS).

**What you will learn:**
- DNS protocol fundamentals (query types, TXT records, encoding constraints)
- DNS tunneling techniques
- Building a custom DNS server in Python
- The severe bandwidth limitations of DNS as a transport

**Where to start reading:**

The current transport is WebSocket-based. The beacon connects at `beacon/beacon.py:466` using `websockets.connect()`. Messages are sent with `ws.send()` and received with `ws.recv()`. The entire transport is abstracted behind these two operations.

The server receives WebSocket connections at `backend/app/beacon/router.py:92`. The `beacon_websocket` function handles the WebSocket lifecycle.

**Hints:**

1. Start by understanding DNS TXT records. A DNS query for `data.yourdomain.com` can return arbitrary text in the TXT record (up to 255 bytes per string, multiple strings per record). The beacon encodes its data in the subdomain labels and reads responses from TXT records.

2. Build a simple DNS server using Python's `dnslib` library. It listens on UDP port 53, receives queries, decodes the subdomain labels to extract beacon data, and responds with TXT records containing task data.

3. The encoding constraint is severe. DNS labels are limited to 63 characters each, and the total domain name cannot exceed 253 characters. Base32 encoding (not Base64, because DNS is case-insensitive) is the standard approach. This means you can fit roughly 150 bytes of raw data per query.

4. Large payloads (like `sysinfo` or `proclist` results) must be chunked across multiple DNS queries. Implement a sequencing protocol: each chunk includes a sequence number and a total count so the server can reassemble them.

5. The beacon's main loop changes from "connect WebSocket, send/receive" to "periodically make DNS queries." Each heartbeat becomes a query like `HEARTBEAT.beaconid.yourdomain.com`. The server responds with either "no tasks" or the encoded task data in a TXT record.

6. This is a major refactor. Consider abstracting the transport layer in the beacon so you can swap between WebSocket and DNS without rewriting the command handlers. Create a `Transport` interface with `send()` and `receive()` methods.

**Files to modify:**
- Major refactor of `beacon/beacon.py` (transport abstraction)
- New DNS server script
- New DNS transport implementation for the beacon

---

## Expert Challenges

---

### Challenge 13: Malleable C2 Profile

**What to build:** Implement traffic shaping where the C2 communication mimics normal HTTP traffic. Make beacon requests look like they are fetching resources from a CDN, a social media API, or a weather service.

**Why it matters:** Network defenders use heuristics to flag unusual traffic. WebSocket connections to a random IP on port 8000 are suspicious by default. But HTTPS requests to what looks like `api.weather.com/v2/forecast?lat=40.7&lon=-74.0` blend into normal traffic. Cobalt Strike's "malleable C2 profiles" are configuration files that define exactly how traffic should look. This is one of the most powerful evasion techniques in modern C2 frameworks.

MITRE ATT&CK reference: T1001.003 (Data Obfuscation: Protocol Impersonation).

**Where to start reading:**

Study the current message format. The beacon sends XOR+Base64 encoded strings over WebSocket. A network observer sees Base64 blobs going to a WebSocket endpoint. This is obviously not normal web traffic.

Look at how the beacon's `pack` function at `beacon/beacon.py:81-86` builds messages and how the server's `unpack` at `protocol.py:45-59` parses them. The transformation happens at these two points.

**Hints:**

1. Research Cobalt Strike's malleable C2 profile format. Read some example profiles to understand what traffic shaping means in practice. Key concepts: URI paths, HTTP headers, parameter encoding, body transforms.

2. Replace the WebSocket transport with HTTPS requests that mimic a legitimate API. For example, the beacon could send heartbeats as `GET /api/v2/feed?user=<encoded_beacon_id>&ts=<encoded_heartbeat>` and receive tasks in the response body wrapped in fake JSON like `{"status": "ok", "data": {"items": ["<encoded_task>"]}}`.

3. Add realistic HTTP headers: `User-Agent`, `Accept`, `Content-Type`, `Cache-Control`. Copy headers from a real browser request to the service you are impersonating.

4. Vary the URI paths. Do not hit the same endpoint every time. Rotate between `/api/feed`, `/api/profile`, `/api/notifications`, etc. Each can carry the same encoded payload but looks like different API calls.

5. The server side needs a corresponding transformation. For each fake API endpoint, the server extracts the real C2 data from the request parameters or body, processes it, and wraps the response in the same fake API format.

---

### Challenge 14: Write a YARA Rule

**What to build:** Write YARA rules that detect this project's beacon source code on disk and its network traffic patterns in a PCAP capture.

**Why it matters:** YARA is the standard tool for malware identification. Threat intelligence teams write YARA rules to hunt for known malware across endpoints and network captures. Writing YARA rules for your own tool teaches you what makes malware identifiable and how to reduce those indicators.

**Where to start reading:**

Study the beacon source at `beacon/beacon.py` for unique strings and patterns:
- The default XOR key at line 41: `"c2-beacon-default-key-change-me"`
- The `REGISTER` message type string at line 468
- The `COMMAND_HANDLERS` dictionary keys at lines 419-430
- Import combinations: `psutil`, `websockets`, `mss`, `pynput` together in one file is unusual
- The `collect_system_info` function at line 105 gathers hostname, OS, username, PID, internal IP, and architecture, which is a distinctive fingerprint

**Hints:**

1. Install YARA (`sudo apt install yara` or `pip install yara-python`) and read the documentation on rule syntax. A basic rule needs: `rule name { strings: $s1 = "pattern" condition: $s1 }`.

2. For detecting the beacon source code on disk, look for unique string combinations. Any single string could appear in legitimate code, so combine multiple strings with `and` conditions. For example: the XOR key AND the `collect_system_info` function name AND the `COMMAND_HANDLERS` variable name.

3. For detecting network traffic, capture a PCAP of the beacon communicating with the server (use `tcpdump` or Wireshark). Look for the WebSocket upgrade request to `/ws/beacon` and the periodic Base64-encoded messages.

4. Test your rules against the beacon file AND against a set of benign Python files to verify you get no false positives. A rule that matches every Python script is useless.

5. Consider writing separate rules: one for "beacon source on disk" (text matching) and one for "beacon traffic in PCAP" (byte pattern matching against the encoded message format).

---

### Challenge 15: Implement Process Injection

**What to build:** Instead of running the beacon as a visible Python process, inject the beacon code into another running process so it hides within a legitimate program.

**Why it matters:** A standalone `python3 beacon.py` process is visible in every process listing. Any system administrator running `ps aux` will see it. Process injection hides the beacon inside a trusted process like `sshd`, `nginx`, or `bash`, making it much harder to detect.

MITRE ATT&CK reference: T1055 (Process Injection).

**Where to start reading:**

The beacon currently runs as a standalone process. Look at `beacon/beacon.py:513-514` where `asyncio.run(main())` starts everything. The `collect_system_info` function at line 105 reports its own PID with `os.getpid()`.

**Hints:**

1. On Linux, research `ptrace`-based injection. The `ptrace` system call allows one process to control another. You can attach to a target process, allocate memory in its address space, write your shellcode or Python bytecode, and create a new thread to execute it.

2. A simpler approach on Linux is `LD_PRELOAD` injection. Create a shared library that starts the beacon in a background thread when loaded. Then start a legitimate program with `LD_PRELOAD=./beacon.so /usr/bin/some_program`. The beacon runs inside that program's process.

3. The Python-specific approach: use `ctypes` to call `dlopen()` and inject a shared library into the current process, or use `/proc/{pid}/mem` to write to another process's memory space (requires root).

4. This is significantly harder than the other challenges. Start by getting `LD_PRELOAD` injection working before attempting `ptrace`. The `ctypes` library in Python can interface with C-level system calls, but you will likely need to write a small C wrapper.

5. Consider the ethical implications. Process injection is a technique used by both red teams (authorized testing) and actual malware. Only test this in isolated lab environments you own. Running this against systems you do not have explicit authorization to test is illegal.

---

## Challenge Yourself Further

These are open-ended projects that go beyond modifying this codebase. They build the broader skills that matter for a career in offensive or defensive security.

**Compare with production C2 frameworks.** Install Sliver (open source, Go-based) or set up a Cobalt Strike trial. Run them side by side with this project. Compare the architecture: how does Sliver handle beacon registration? How does Cobalt Strike's team server differ from our `OpsManager`? What features do they have that we skipped? Document the differences.

**Capture and analyze your own traffic.** Run Wireshark while the beacon communicates with the server. Save the capture as a PCAP file. Identify the WebSocket handshake, the heartbeat pattern, and the task/result exchanges. Write Snort or Suricata rules that would detect this traffic on a corporate network. Test those rules against the PCAP to verify they trigger.

**Deploy over a real network.** Run the C2 server on a VPS (DigitalOcean, AWS, Linode) and the beacon on a different machine, either another VPS or a local VM. This exposes you to real networking challenges: firewalls, NAT traversal, DNS resolution, TLS certificates for secure WebSocket connections, and latency. Most local development bypasses these entirely.

**Map to MITRE ATT&CK.** Read the ATT&CK pages for every technique our commands implement. The beacon supports: T1059.004 (shell), T1082 (sysinfo), T1057 (proclist), T1105 (upload/download), T1113 (screenshot), T1056.001 (keylogging), T1053.003 (persist via cron), T1029 (sleep/jitter for scheduled transfer). For each technique, read the "Detection" section. What would a defender look for? Does our implementation leave those artifacts?

**Build a lab with detection tooling.** Set up an ELK stack (Elasticsearch, Logstash, Kibana) or Wazuh on the same network as the beacon. Configure Sysmon (Windows) or auditd (Linux) to log process creation, network connections, and file modifications. Run the beacon and see what alerts fire. This gives you the defender's perspective on every command you execute.

---

## Challenge Completion Tracker

Use this to track your progress. Check off each challenge as you complete it.

- [ ] Easy 1: Add a `pwd` Command
- [ ] Easy 2: Add Beacon Uptime Display
- [ ] Easy 3: Add a `clear` Terminal Command
- [ ] Easy 4: Add Connection Count to Header
- [ ] Intermediate 5: Add Operator Authentication
- [ ] Intermediate 6: Add More Quick Action Buttons
- [ ] Intermediate 7: Task History Persistence
- [ ] Intermediate 8: Add AES-256 Encryption
- [ ] Advanced 9: Multi-Operator Support with Roles
- [ ] Advanced 10: Beacon Staging
- [ ] Advanced 11: Build a Detection Tool
- [ ] Advanced 12: Add DNS-Based C2 Channel
- [ ] Expert 13: Malleable C2 Profile
- [ ] Expert 14: Write a YARA Rule
- [ ] Expert 15: Implement Process Injection
