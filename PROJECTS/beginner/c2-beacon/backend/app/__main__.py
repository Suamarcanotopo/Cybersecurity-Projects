"""
AngelaMos | 2026
__main__.py

FastAPI application factory and server entry point

create_app assembles the FastAPI instance with CORS middleware, health
and root endpoints, and all three routers. The lifespan handler
initializes the database and creates the shared registry,
task_manager, and ops_manager singletons stored on app.state.

Connects to:
  config.py - reads all settings
  database.py - calls init_db()
  beacon/registry.py - creates BeaconRegistry singleton
  beacon/tasking.py - creates TaskManager singleton
  beacon/router.py - mounts beacon WebSocket router
  ops/manager.py - creates OpsManager singleton
  ops/router.py - mounts operator WebSocket and REST routers
"""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.beacon.registry import BeaconRegistry
from app.beacon.router import router as beacon_ws_router
from app.beacon.tasking import TaskManager
from app.config import settings
from app.database import init_db
from app.ops.manager import OpsManager
from app.ops.router import rest_router as ops_rest_router
from app.ops.router import ws_router as ops_ws_router


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """
    Application lifespan handler for startup and shutdown
    """
    logging.basicConfig(
        level = getattr(logging,
                        settings.LOG_LEVEL),
        format = "%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    await init_db()
    app.state.registry = BeaconRegistry()
    app.state.task_manager = TaskManager()
    app.state.ops_manager = OpsManager()
    logging.getLogger(__name__).info(
        "%s v%s started",
        settings.APP_NAME,
        settings.APP_VERSION
    )
    yield


def create_app() -> FastAPI:
    """
    Application factory
    """
    app = FastAPI(
        title = settings.APP_NAME,
        version = settings.APP_VERSION,
        description = "Educational C2 beacon server for security research",
        lifespan = lifespan,
        root_path = "/api",
        openapi_url = "/openapi.json",
        docs_url = "/docs",
        redoc_url = "/redoc",
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins = settings.CORS_ORIGINS,
        allow_credentials = True,
        allow_methods = ["GET",
                         "POST",
                         "OPTIONS"],
        allow_headers = ["*"],
    )

    @app.get("/health", tags = ["health"])
    async def health() -> dict[str, str]:
        """
        Health check endpoint for container orchestration
        """
        return {"status": "healthy"}

    @app.get("/", tags = ["root"])
    async def root() -> dict[str, str]:
        """
        API information endpoint
        """
        return {
            "name": settings.APP_NAME,
            "version": settings.APP_VERSION,
            "docs": "/api/docs",
        }

    app.include_router(beacon_ws_router, prefix = "/ws")
    app.include_router(ops_ws_router, prefix = "/ws")
    app.include_router(ops_rest_router)

    return app


app = create_app()

if __name__ == "__main__":
    uvicorn.run(
        "app.__main__:app",
        host = settings.HOST,
        port = settings.PORT,
        reload = settings.RELOAD,
    )
