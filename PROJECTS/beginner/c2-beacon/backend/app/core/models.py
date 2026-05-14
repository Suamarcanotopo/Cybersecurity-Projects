"""
AngelaMos | 2026
models.py

Pydantic models and command types shared across the C2 server

Defines the data types used throughout the server: CommandType (the
supported C2 commands mapped to MITRE ATT&CK techniques), beacon
registration and storage models, and the full task lifecycle from
request to result.

Key exports:
  CommandType - enum of supported beacon commands
  BeaconMeta, BeaconRecord - beacon registration and database types
  TaskRequest, TaskRecord, TaskResult - task lifecycle types

Connects to:
  beacon/registry.py - uses BeaconMeta, BeaconRecord
  beacon/tasking.py - uses TaskRecord, TaskResult
  beacon/router.py - uses BeaconMeta, TaskResult
  ops/router.py - uses CommandType, TaskRecord
"""

from datetime import UTC, datetime
from enum import StrEnum

from pydantic import BaseModel, Field


class CommandType(StrEnum):
    """
    Supported beacon command types mapped to MITRE ATT&CK techniques
    """

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
    """
    Metadata collected from a beacon during registration
    """

    hostname: str
    os: str
    username: str
    pid: int
    internal_ip: str
    arch: str


class BeaconRecord(BeaconMeta):
    """
    Full beacon record including server-assigned fields
    """

    id: str
    first_seen: str
    last_seen: str


class TaskRequest(BaseModel):
    """
    Operator-submitted task targeting a specific beacon
    """

    beacon_id: str
    command: CommandType
    args: str | None = None


class TaskRecord(BaseModel):
    """
    Persisted task with tracking metadata
    """

    id: str
    beacon_id: str
    command: CommandType
    args: str | None = None
    status: str = "pending"
    created_at: str = Field(default_factory = lambda: datetime.now(UTC).isoformat())
    completed_at: str | None = None


class TaskResult(BaseModel):
    """
    Result returned by a beacon after executing a task
    """

    id: str
    task_id: str
    output: str | None = None
    error: str | None = None
    created_at: str = Field(default_factory = lambda: datetime.now(UTC).isoformat())
