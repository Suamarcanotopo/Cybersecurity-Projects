"""
©AngelaMos | 2026
extensions.py

MongoDB and Redis connection management

Initializes and exposes the MongoEngine and Redis clients used
throughout the backend. init_mongo and init_redis are called by
the app factory during startup. get_redis is called anywhere that
needs direct Redis access, raising if the client was never initialized.

Key exports:
  init_mongo - connects MongoEngine to MongoDB
  init_redis - creates the module-level Redis client
  get_redis - returns the Redis client or raises RuntimeError

Connects to:
  __init__.py - calls init_mongo and init_redis
  core/streaming.py - calls get_redis
"""

from typing import TYPE_CHECKING

import redis
from flask import Flask
from mongoengine import connect, disconnect

if TYPE_CHECKING:
    from redis import Redis


_redis_client: Redis[str] | None = None


def init_mongo(app: Flask) -> None:
    """
    Connect MongoEngine to the configured MongoDB instance
    """
    connect(
        db = app.config["MONGO_DB"],
        host = app.config["MONGO_URI"],
        alias = "default",
    )


def close_mongo() -> None:
    """
    Disconnect MongoEngine from MongoDB
    """
    disconnect(alias = "default")


def init_redis(app: Flask) -> None:
    """
    Initialize the module level Redis client from app config
    """
    global _redis_client
    _redis_client = redis.from_url(
        app.config["REDIS_URL"],
        decode_responses = True,
    )


def get_redis() -> Redis[str]:
    """
    Return the initialized Redis client or raise if not ready
    """
    if _redis_client is None:
        raise RuntimeError("Redis not initialized")
    return _redis_client
