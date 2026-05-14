"""
ⒸAngelaMos | 2025
base.py

Abstract base class for rate limiting algorithms

Defines the interface that all algorithm implementations must
follow: a name property, a check() method that decides whether
a request is allowed, and a get_current_usage() method for
reporting. Each algorithm receives a storage backend and operates
against it, but the base class doesn't care which backend it is.

Key exports:
  BaseAlgorithm - ABC with name, check(), get_current_usage()

Connects to:
  fixed_window.py - subclasses BaseAlgorithm
  sliding_window.py - subclasses BaseAlgorithm
  token_bucket.py - subclasses BaseAlgorithm
"""
# pylint: disable=unnecessary-ellipsis

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from fastapi_420.storage import Storage
    from fastapi_420.types import RateLimitResult, RateLimitRule


class BaseAlgorithm(ABC):
    """
    Abstract base class for rate limiting algorithms
    """
    @property
    @abstractmethod
    def name(self) -> str:
        """
        Algorithm name for logging and debugging
        """
        ...

    @abstractmethod
    async def check(
        self,
        storage: Storage,
        key: str,
        rule: RateLimitRule,
        timestamp: float | None = None,
    ) -> RateLimitResult:
        """
        Check if request is allowed under rate limit
        """
        ...

    @abstractmethod
    async def get_current_usage(
        self,
        storage: Storage,
        key: str,
        rule: RateLimitRule,
    ) -> int:
        """
        Get current usage count without incrementing
        """
        ...
