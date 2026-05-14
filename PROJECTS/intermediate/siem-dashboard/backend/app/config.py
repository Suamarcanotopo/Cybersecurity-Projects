"""
©AngelaMos | 2026
config.py

Pydantic Settings configuration for the SIEM backend

All runtime configuration is loaded from environment variables or
a .env file. Covers MongoDB, Redis, JWT, CORS, rate limiting, Redis
Streams, scenario playback, and dashboard aggregation settings.
The module-level settings singleton is imported across the entire app.

Key exports:
  Settings - pydantic-settings class with all config fields
  settings - singleton instance used by all other modules
"""

from pathlib import Path
from pydantic_settings import (
    BaseSettings,
    SettingsConfigDict,
)


class Settings(BaseSettings):
    """
    Application settings loaded from environment variables
    """
    model_config = SettingsConfigDict(
        env_file = ".env",
        env_file_encoding = "utf-8",
        case_sensitive = False,
    )

    MONGO_URI: str = "mongodb://mongo:27017/siem"
    MONGO_DB: str = "siem"

    REDIS_URL: str = "redis://redis:6379/0"

    SECRET_KEY: str = "change-me-in-production"
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRATION_HOURS: int = 24

    CORS_ORIGINS: list[str] = ["http://localhost:5173"]

    LOG_STREAM_KEY: str = "siem:logs"
    ALERT_STREAM_KEY: str = "siem:alerts"
    STREAM_MAXLEN: int = 10000
    STREAM_READ_COUNT: int = 10
    STREAM_BLOCK_MS: int = 2000
    SSE_READ_COUNT: int = 50
    SSE_BLOCK_MS: int = 3000
    CONSUMER_GROUP: str = "siem-correlation"
    CONSUMER_NAME: str = "engine-1"

    SCENARIO_PLAYBOOK_DIR: str = str(Path(__file__).parent / "scenarios" / "playbooks")
    SCENARIO_MIN_SPEED: float = 0.1
    SCENARIO_MAX_SPEED: float = 10.0

    CORRELATION_COOLDOWN_SECONDS: int = 300
    CORRELATION_RULE_CACHE_SECONDS: int = 30
    CORRELATION_ERROR_BACKOFF_SECONDS: float = 1.0
    RULE_TEST_MAX_HOURS: int = 72

    DEFAULT_PAGE_SIZE: int = 50
    MAX_PAGE_SIZE: int = 200

    TIMELINE_DEFAULT_HOURS: int = 24
    TIMELINE_BUCKET_MINUTES: int = 15
    TOP_SOURCES_LIMIT: int = 10

    RATELIMIT_STRATEGY: str = "moving-window"
    RATELIMIT_HEADERS_ENABLED: bool = True
    RATELIMIT_SWALLOW_ERRORS: bool = True
    RATELIMIT_DEFAULT: str = "200/minute"
    RATELIMIT_AUTH: str = "10/minute"

    LOG_LEVEL: str = "INFO"
    DEBUG: bool = False


settings = Settings()
