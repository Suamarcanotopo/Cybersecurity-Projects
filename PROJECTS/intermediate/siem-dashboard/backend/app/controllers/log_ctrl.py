"""
©AngelaMos | 2026
log_ctrl.py

Business logic for log event operations

Handles paginated listing, single event lookup, log ingestion
(normalize, classify, persist, publish), full-text search, the SSE
log stream, and forensic pivot queries by IP, username, or hostname.

Key exports:
  list_logs, get_log, ingest_log, search_logs, stream_logs, pivot

Connects to:
  models/LogEvent.py - queries and event creation
  engine/normalizer.py - calls normalize
  engine/severity.py - calls classify
  core/streaming.py - calls publish_event, sse_generator
  config.py - reads LOG_STREAM_KEY
  routes/logs.py - called from route handlers
"""

from typing import Any

from flask import Response, g

from app.config import settings
from app.core.streaming import publish_event, sse_generator
from app.engine.normalizer import normalize
from app.engine.severity import classify
from app.models.LogEvent import LogEvent


def list_logs() -> dict[str, Any]:
    """
    Return paginated and filtered log events
    """
    params = g.validated
    filters = {}
    if params.source_type:
        filters["source_type"] = params.source_type
    if params.severity:
        filters["severity"] = params.severity
    if params.source_ip:
        filters["source_ip"] = params.source_ip
    if params.event_type:
        filters["event_type"] = params.event_type

    qs = LogEvent.objects(**filters).order_by("-timestamp")
    return LogEvent.paginate(
        queryset = qs,
        page = params.page,
        per_page = params.per_page,
    )


def get_log(log_id: str) -> LogEvent:
    """
    Return a single log event by ID
    """
    return LogEvent.get_by_id(log_id)


def ingest_log() -> LogEvent:
    """
    Normalize, classify, persist, and publish a log event
    """
    raw = g.validated.model_dump(exclude_none = True)

    normalized = normalize(raw)
    severity = classify(normalized)

    event = LogEvent.create_event(
        **normalized,
        severity = severity,
    )

    publish_event(
        settings.LOG_STREAM_KEY,
        {
            "id": str(event.id),
            "timestamp": str(event.timestamp),
            "source_type": event.source_type,
            "severity": event.severity,
            "event_type": event.event_type,
            "source_ip": event.source_ip,
            "dest_ip": event.dest_ip,
            "hostname": event.hostname,
            "username": event.username,
        },
    )

    return event


def search_logs() -> dict[str, Any]:
    """
    Full text search across log events
    """
    params = g.validated
    return LogEvent.search(
        query = params.q,
        page = params.page,
        per_page = params.per_page,
    )


def stream_logs() -> Response:
    """
    SSE endpoint that tails the log Redis Stream
    """
    return Response(
        sse_generator(settings.LOG_STREAM_KEY,
                      event_type = "log"),
        mimetype = "text/event-stream",
        headers = {
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


def pivot() -> list[Any]:
    """
    Forensic pivot by IP, username, or hostname
    """
    params = g.validated
    if params.ip:
        return LogEvent.get_by_source_ip(params.ip)
    if params.username:
        return LogEvent.get_by_username(params.username)
    if params.hostname:
        return LogEvent.get_by_hostname(params.hostname)
    return []
