"""
©AngelaMos | 2026
websocket.py
"""

import json
import logging
import secrets
from uuid import UUID

from fastapi import (
    APIRouter,
    WebSocket,
    WebSocketDisconnect,
)

from app.config import SESSION_COOKIE_NAME
from app.core.redis_manager import redis_manager
from app.core.websocket_manager import connection_manager
from app.services.websocket_service import websocket_service


logger = logging.getLogger(__name__)

router = APIRouter(prefix = "/ws", tags = ["websocket"])


async def _resolve_user(websocket: WebSocket) -> UUID | None:
    """
    Resolve the authenticated user from the session cookie or close the socket
    """
    token = websocket.cookies.get(SESSION_COOKIE_NAME)
    if not token:
        await websocket.close(code = 4401, reason = "Not authenticated")
        return None

    user_id_str = await redis_manager.get_session_user(token)
    if user_id_str is None:
        await websocket.close(code = 4401, reason = "Session expired")
        return None

    try:
        return UUID(user_id_str)
    except ValueError:
        await websocket.close(code = 4401, reason = "Invalid session")
        return None


@router.websocket("")
async def websocket_endpoint(websocket: WebSocket) -> None:
    """
    Main WebSocket endpoint authenticated via the session cookie
    """
    user_uuid = await _resolve_user(websocket)
    if user_uuid is None:
        return

    connected = await connection_manager.connect(websocket, user_uuid)
    if not connected:
        return

    try:
        while True:
            data = await websocket.receive_text()

            try:
                message = json.loads(data)
                await websocket_service.route_message(
                    websocket,
                    user_uuid,
                    message,
                )
            except json.JSONDecodeError:
                logger.warning(
                    "Invalid JSON from user %s",
                    user_uuid,
                )
                await websocket.send_json(
                    {
                        "type": "error",
                        "error_code": "invalid_json",
                        "error_message": "Invalid JSON format",
                    }
                )
            except Exception as exc:
                error_id = secrets.token_hex(8)
                logger.error(
                    "[%s] Error handling message from %s: %s",
                    error_id,
                    user_uuid,
                    exc,
                )
                await websocket.send_json(
                    {
                        "type": "error",
                        "error_code": "processing_error",
                        "error_message": "Internal error",
                        "error_id": error_id,
                    }
                )

    except WebSocketDisconnect:
        logger.info("WebSocket disconnected for user %s", user_uuid)
    except Exception as exc:
        logger.error("WebSocket error for user %s: %s", user_uuid, exc)
    finally:
        await connection_manager.disconnect(websocket, user_uuid)
