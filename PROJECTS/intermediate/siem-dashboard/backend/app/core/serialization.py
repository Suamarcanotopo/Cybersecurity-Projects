"""
©AngelaMos | 2026
serialization.py

MongoEngine-to-JSON serialization utilities

Converts MongoEngine documents, querysets, and embedded documents
to JSON-safe dicts by recursively handling ObjectId, datetime,
and nested types. auto_serialize is the main dispatch function
called by the R() decorator to convert any controller return value
before passing it to jsonify.

Key exports:
  serialize_document - converts a single MongoEngine document to dict
  auto_serialize - dispatches serialization based on object type

Connects to:
  core/decorators/response.py - calls auto_serialize on every response
"""

from typing import Any
from datetime import datetime

from bson import ObjectId
from mongoengine import (
    Document,
    EmbeddedDocument,
    QuerySet,
)
from pydantic import BaseModel


def serialize_value(value: Any) -> Any:
    """
    Convert a single value to a JSON safe representation
    """
    if value is None:
        return None
    if isinstance(value, ObjectId):
        return str(value)
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, EmbeddedDocument):
        return serialize_document(value)
    if isinstance(value, list):
        return [serialize_value(v) for v in value]
    if isinstance(value, dict):
        return {k: serialize_value(v) for k, v in value.items()}
    return value


def serialize_document(
    doc: Document | EmbeddedDocument,
) -> dict[str,
          Any]:
    """
    Recursively convert a MongoEngine document to a JSON safe dict
    """
    result: dict[str, Any] = {}
    for field_name in doc._fields:
        value = getattr(doc, field_name, None)
        if field_name == "id" and isinstance(value, ObjectId):
            result["id"] = str(value)
            continue
        result[field_name] = serialize_value(value)
    return result


def auto_serialize(obj: Any) -> Any:
    """
    Dispatch serialization based on the object type
    """
    if obj is None:
        return None
    if isinstance(obj, Document):
        return serialize_document(obj)
    if isinstance(obj, QuerySet):
        return [serialize_document(doc) for doc in obj]
    if isinstance(obj, list):
        return [auto_serialize(item) for item in obj]
    if isinstance(obj, BaseModel):
        return obj.model_dump(mode = "json")
    if isinstance(obj, dict):
        return {k: auto_serialize(v) for k, v in obj.items()}
    return obj
