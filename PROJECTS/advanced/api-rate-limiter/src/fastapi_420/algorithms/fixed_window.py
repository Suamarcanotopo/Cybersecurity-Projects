"""
ⒸAngelaMos | 2025
fixed_window.py

Fixed window counter rate limiting algorithm

The simplest algorithm. Divides time into fixed-size windows and
counts requests in each. Has the well-known boundary burst problem
where a client can make 2x the limit by timing requests at the
edge of two adjacent windows. Includes a special codepath for
Redis that uses the atomic increment_fixed_window() Lua script
instead of the generic sliding window storage methods.

Connects to:
  base.py - extends BaseAlgorithm
  redis_backend.py - checks isinstance for Redis-specific path
"""

from __future__ import annotations

import time
from typing import TYPE_CHECKING

from fastapi_420.algorithms.base import BaseAlgorithm
from fastapi_420.storage.redis_backend import RedisStorage
from fastapi_420.types import Algorithm

if TYPE_CHECKING:
    from fastapi_420.storage import Storage
    from fastapi_420.types import RateLimitResult, RateLimitRule


class FixedWindowAlgorithm(BaseAlgorithm):
    """
    Fixed window counter algorithm

    Simple implementation but suffers from boundary burst problem:
    clients can make 2x the limit by timing requests at window edges.

    Use sliding_window for production unless simplicity is required.
    """
    @property
    def name(self) -> str:
        return Algorithm.FIXED_WINDOW.value

    async def check(
        self,
        storage: Storage,
        key: str,
        rule: RateLimitRule,
        timestamp: float | None = None,
    ) -> RateLimitResult:
        """
        Check and increment counter using fixed window algorithm
        """
        if isinstance(storage, RedisStorage):
            return await storage.increment_fixed_window(
                key = key,
                window_seconds = rule.window_seconds,
                limit = rule.requests,
                timestamp = timestamp,
            )

        return await storage.increment(
            key = key,
            window_seconds = rule.window_seconds,
            limit = rule.requests,
            timestamp = timestamp,
        )

    async def get_current_usage(
        self,
        storage: Storage,
        key: str,
        rule: RateLimitRule,
    ) -> int:
        """
        Get current window count without incrementing
        """
        now = time.time()
        current_window = int(now // rule.window_seconds)
        window_key = f"{key}:{current_window}"

        state = await storage.get_window_state(
            key = window_key,
            window_seconds = rule.window_seconds,
        )

        return state.current_count
