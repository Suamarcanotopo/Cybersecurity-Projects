"""
AngelaMos | 2026
registry.py

Tracks active beacon WebSocket connections with SQLite persistence

BeaconRegistry holds an in-memory dict of live connections keyed by
beacon ID alongside the SQLite beacons table. register/unregister
update both stores. is_active and get_connection read from memory;
get_all and get_one query the database.

Connects to:
  core/models.py - uses BeaconMeta, BeaconRecord
  beacon/router.py - registers and unregisters connections
  ops/router.py - reads beacon list and active status
  __main__.py - creates singleton on startup
  tests/test_registry.py - tests all registry methods
"""

from datetime import UTC, datetime

import aiosqlite
from fastapi import WebSocket

from app.core.models import BeaconMeta, BeaconRecord


class BeaconRegistry:
    """
    Tracks active beacon WebSocket connections backed by SQLite persistence
    """
    def __init__(self) -> None:
        """
        Initialize empty connection store
        """
        self._connections: dict[str, WebSocket] = {}

    async def register(
        self,
        beacon_id: str,
        meta: BeaconMeta,
        ws: WebSocket,
        db: aiosqlite.Connection,
    ) -> None:
        """
        Register a beacon connection in memory and upsert to database
        """
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
        """
        Remove beacon from active connections and update last_seen
        """
        self._connections.pop(beacon_id, None)
        now = datetime.now(UTC).isoformat()
        await db.execute(
            "UPDATE beacons SET last_seen = ? WHERE id = ?",
            (now,
             beacon_id),
        )
        await db.commit()

    def get_connection(self, beacon_id: str) -> WebSocket | None:
        """
        Retrieve the active WebSocket for a beacon
        """
        return self._connections.get(beacon_id)

    def is_active(self, beacon_id: str) -> bool:
        """
        Check if a beacon has an active WebSocket connection
        """
        return beacon_id in self._connections

    def list_active_ids(self) -> list[str]:
        """
        Return IDs of all currently connected beacons
        """
        return list(self._connections.keys())

    async def get_all(self, db: aiosqlite.Connection) -> list[BeaconRecord]:
        """
        Retrieve all beacon records from the database
        """
        cursor = await db.execute("SELECT * FROM beacons ORDER BY last_seen DESC")
        rows = await cursor.fetchall()
        return [BeaconRecord(**dict(row)) for row in rows]

    async def get_one(
        self,
        beacon_id: str,
        db: aiosqlite.Connection,
    ) -> BeaconRecord | None:
        """
        Retrieve a single beacon record by ID
        """
        cursor = await db.execute("SELECT * FROM beacons WHERE id = ?",
                                  (beacon_id,
                                   ))
        row = await cursor.fetchone()
        if row is None:
            return None
        return BeaconRecord(**dict(row))

    async def update_last_seen(
        self,
        beacon_id: str,
        db: aiosqlite.Connection,
    ) -> None:
        """
        Update the last_seen timestamp for a beacon heartbeat
        """
        now = datetime.now(UTC).isoformat()
        await db.execute(
            "UPDATE beacons SET last_seen = ? WHERE id = ?",
            (now,
             beacon_id),
        )
        await db.commit()
