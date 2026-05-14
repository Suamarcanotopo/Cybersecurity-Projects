"""
©AngelaMos | 2026
factory.py
"""

import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import ORJSONResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from slowapi.errors import RateLimitExceeded

from app.api.auth import limiter as auth_limiter
from app.api.auth import router as auth_router
from app.api.encryption import router as encryption_router
from app.api.rooms import router as rooms_router
from app.api.websocket import router as websocket_router
from app.config import (
    APP_DESCRIPTION,
    APP_STATUS,
    APP_VERSION,
    GZIP_MINIMUM_SIZE,
    settings,
)
from app.core.exception_handlers import (
    rate_limit_exceeded_handler,
    register_exception_handlers,
)
from app.core.redis_manager import redis_manager
from app.core.surreal_manager import surreal_db
from app.models.Base import init_db
from app.schemas.common import (
    HealthResponse,
    RootResponse,
)


logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None]:
    """
    Application lifespan manager for startup and shutdown events
    """
    logger.info("Starting %s in %s mode", settings.APP_NAME, settings.ENV)

    await init_db()
    logger.info("PostgreSQL database initialized")

    await redis_manager.connect()
    logger.info("Redis connected")

    await surreal_db.connect()
    logger.info("SurrealDB connected")

    yield

    logger.info("Shutting down application")

    await redis_manager.disconnect()
    await surreal_db.disconnect()


def create_app() -> FastAPI:
    """
    Create and configure the FastAPI application instance
    """
    app = FastAPI(
        title = settings.APP_NAME,
        description = APP_DESCRIPTION,
        version = APP_VERSION,
        openapi_version = "3.1.0",
        docs_url = "/docs" if settings.is_development else None,
        redoc_url = "/redoc" if settings.is_development else None,
        default_response_class = ORJSONResponse,
        lifespan = lifespan,
    )

    app.state.limiter = auth_limiter
    app.add_exception_handler(RateLimitExceeded, rate_limit_exceeded_handler)

    app.add_middleware(
        CORSMiddleware,
        allow_origins = settings.CORS_ORIGINS,
        allow_credentials = True,
        allow_methods = ["*"],
        allow_headers = ["*"],
        expose_headers = ["*"],
    )

    app.add_middleware(GZipMiddleware, minimum_size = GZIP_MINIMUM_SIZE)

    register_exception_handlers(app)

    @app.get("/", tags = ["root"])
    async def root() -> RootResponse:
        """
        Root endpoint returning API status
        """
        return RootResponse(
            app = settings.APP_NAME,
            version = APP_VERSION,
            status = APP_STATUS,
            environment = settings.ENV,
        )

    @app.get("/health", tags = ["health"])
    async def health() -> HealthResponse:
        """
        Health check endpoint for monitoring
        """
        return HealthResponse(status = "healthy")

    app.include_router(auth_router)
    app.include_router(rooms_router)
    app.include_router(encryption_router)
    app.include_router(websocket_router)

    return app
