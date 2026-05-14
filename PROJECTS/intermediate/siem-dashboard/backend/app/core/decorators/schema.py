"""
©AngelaMos | 2026
schema.py

S() decorator for Pydantic request validation

Validates incoming request data against a Pydantic model and stores
the result on flask.g.validated for the controller to read. Supports
auto (method-driven), query, and body source selection. Raises
ValidationError with structured field-level detail on failure.

Key exports:
  S - factory returning a decorator; takes a schema class and source param

Connects to:
  core/errors.py - raises ValidationError on Pydantic failure
  routes/ - applied to routes that accept request parameters
"""

import functools
from typing import Any, Literal
from collections.abc import Callable

from flask import g, request
from pydantic import (
    BaseModel,
    ValidationError as PydanticValidationError,
)
from app.core.errors import ValidationError


def S(  # noqa: N802
    schema_class: type[BaseModel],
    source: Literal["auto",
                    "query",
                    "body"] = "auto",
) -> Callable[..., Any]:
    """
    Validate request data with Pydantic and store on g.validated
    """
    def decorator(fn: Callable[..., Any]) -> Callable[..., Any]:
        @functools.wraps(fn)
        def wrapper(*args: Any, **kwargs: Any) -> Any:
            raw = _extract_data(source)
            try:
                g.validated = schema_class.model_validate(raw)
            except PydanticValidationError as exc:
                raise ValidationError(
                    message = "Validation failed",
                    errors = [
                        {
                            "field": ".".join(str(loc) for loc in e["loc"]),
                            "message": e["msg"],
                            "type": e["type"],
                        } for e in exc.errors()
                    ],
                ) from exc
            return fn(*args, **kwargs)

        return wrapper

    return decorator


def _extract_data(
    source: Literal["auto",
                    "query",
                    "body"],
) -> dict[str,
          Any]:
    """
    Pull raw data from the request based on the declared source
    """
    if source == "query":
        return dict(request.args)
    if source == "body":
        return _get_body()
    if source == "auto":
        if request.method in ("GET", "DELETE", "HEAD", "OPTIONS"):
            return dict(request.args)
        return _get_body()
    return {}


def _get_body() -> dict[str, Any]:
    """
    Extract JSON body from the request or return empty dict
    """
    data = request.get_json(silent = True)
    if data is None:
        return {}
    return data  # type: ignore[no-any-return]
