"""
©AngelaMos | 2026
logs.py

Route handlers for the log events API (/v1/logs)

Mounts GET /, GET /<log_id>, POST /ingest, GET /search, GET /stream
(SSE), and GET /pivot. The ingest endpoint is unauthenticated to
support direct log shipping from sources.

Connects to:
  controllers/log_ctrl.py - business logic
  schemas/log_event.py - LogIngestRequest, LogQueryParams, LogSearchParams, PivotParams
  routes/__init__.py - logs_bp registered here
"""

from typing import Any

from flask import Blueprint

from app.controllers import log_ctrl
from app.core.decorators import endpoint, S, R
from app.schemas.log_event import (
    LogIngestRequest,
    LogQueryParams,
    LogSearchParams,
    PivotParams,
)


logs_bp = Blueprint("logs", __name__)


@logs_bp.get("")
@endpoint()
@S(LogQueryParams, source = "query")
@R()
def list_logs() -> Any:
    """
    Return paginated and filtered log events
    """
    return log_ctrl.list_logs()


@logs_bp.get("/<log_id>")
@endpoint()
@R()
def get_log(log_id: str) -> Any:
    """
    Return a single log event by ID
    """
    return log_ctrl.get_log(log_id)


@logs_bp.post("/ingest")
@endpoint(auth_required = False)
@S(LogIngestRequest)
@R(status = 201)
def ingest_log() -> Any:
    """
    Ingest a raw log event into the pipeline
    """
    return log_ctrl.ingest_log()


@logs_bp.get("/search")
@endpoint()
@S(LogSearchParams, source = "query")
@R()
def search_logs() -> Any:
    """
    Full text search across log events
    """
    return log_ctrl.search_logs()


@logs_bp.get("/stream")
@endpoint()
def stream_logs() -> Any:
    """
    SSE stream of real-time log events
    """
    return log_ctrl.stream_logs()


@logs_bp.get("/pivot")
@endpoint()
@S(PivotParams, source = "query")
@R()
def pivot() -> Any:
    """
    Forensic pivot by IP, username, or hostname
    """
    return log_ctrl.pivot()
