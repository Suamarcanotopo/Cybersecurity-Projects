"""
©AngelaMos | 2026
log_event.py

Pydantic schemas for log event endpoints

Covers raw log ingestion (LogIngestRequest with extra-field passthrough),
paginated listing (LogQueryParams), full-text search (LogSearchParams),
and forensic pivot lookups (PivotParams).

Key exports:
  LogIngestRequest - raw event ingestion allowing extra metadata fields
  LogQueryParams - listing filters with pagination
  LogSearchParams - search query with pagination
  PivotParams - pivot lookup by IP, username, or hostname

Connects to:
  config.py - reads DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE
  routes/logs.py - passed to S()
"""

from typing import Any

from pydantic import BaseModel, Field

from app.config import settings


class LogIngestRequest(BaseModel):
    """
    Raw log event submitted for ingestion
    """
    source_type: str
    event_type: str | None = None
    source_ip: str | None = None
    dest_ip: str | None = None
    source_port: int | None = None
    dest_port: int | None = None
    hostname: str | None = None
    username: str | None = None
    mitre_tactic: str | None = None
    mitre_technique: str | None = None
    message: str | None = None
    metadata: dict[str, Any] | None = None

    model_config = {"extra": "allow"}


class LogQueryParams(BaseModel):
    """
    Filters for listing log events
    """
    page: int = Field(default = 1, ge = 1)
    per_page: int = Field(
        default = settings.DEFAULT_PAGE_SIZE,
        ge = 1,
        le = settings.MAX_PAGE_SIZE,
    )
    source_type: str | None = None
    severity: str | None = None
    source_ip: str | None = None
    event_type: str | None = None


class LogSearchParams(BaseModel):
    """
    Parameters for full text log search
    """
    q: str = Field(min_length = 1)
    page: int = Field(default = 1, ge = 1)
    per_page: int = Field(
        default = settings.DEFAULT_PAGE_SIZE,
        ge = 1,
        le = settings.MAX_PAGE_SIZE,
    )


class PivotParams(BaseModel):
    """
    Query params for forensic pivot lookups
    """
    ip: str | None = None
    username: str | None = None
    hostname: str | None = None
