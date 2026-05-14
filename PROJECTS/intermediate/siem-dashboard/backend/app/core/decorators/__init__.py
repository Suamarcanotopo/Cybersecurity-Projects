"""
©AngelaMos | 2026
decorators/__init__.py
"""

from app.core.decorators.endpoint import endpoint
from app.core.decorators.response import R
from app.core.decorators.schema import S


__all__ = ["R", "S", "endpoint"]
