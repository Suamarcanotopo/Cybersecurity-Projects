"""
AngelaMos | 2026
protocol.py

Protocol envelope types and pack/unpack for all WebSocket messages

Defines the shared message format for beacon/server communication.
MessageType enumerates the five protocol states. pack serializes a
Message to an encoded string; unpack decodes and validates the result,
raising ValueError on any malformed input.

Key exports:
  MessageType - REGISTER, HEARTBEAT, TASK, RESULT, ERROR
  Message - protocol envelope model
  pack - serialize and encode a Message to a wire string
  unpack - decode and validate a raw wire string into a Message

Connects to:
  encoding.py - calls encode and decode
  beacon/router.py - calls pack, unpack
  tests/test_protocol.py - tests pack/unpack roundtrips
"""

import binascii
import json
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, ValidationError

from app.core.encoding import decode, encode


class MessageType(StrEnum):
    """
    WebSocket message types in the C2 protocol
    """

    REGISTER = "REGISTER"
    HEARTBEAT = "HEARTBEAT"
    TASK = "TASK"
    RESULT = "RESULT"
    ERROR = "ERROR"


class Message(BaseModel):
    """
    Protocol envelope wrapping all WebSocket communications
    """

    type: MessageType
    payload: dict[str, Any]


def pack(message: Message, key: str) -> str:
    """
    Serialize a Message to an XOR+Base64 encoded string
    """
    raw_json = message.model_dump_json()
    return encode(raw_json, key)


def unpack(raw: str, key: str) -> Message:
    """
    Decode an XOR+Base64 string into a validated Message
    """
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
