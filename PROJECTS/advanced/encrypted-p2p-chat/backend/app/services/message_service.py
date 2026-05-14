"""
©AngelaMos | 2026
message_service.py
"""

import logging
from typing import Any
from uuid import UUID
from datetime import UTC, datetime

from sqlmodel import select
from sqlmodel.ext.asyncio.session import AsyncSession

from app.core.exceptions import (
    DatabaseError,
    UserNotFoundError,
)
from app.core.surreal_manager import surreal_db
from app.models.User import User


logger = logging.getLogger(__name__)


class MessageService:
    """
    Pass-through message storage service for client-encrypted messages
    """
    async def store_encrypted_message(
        self,
        session: AsyncSession,
        sender_id: UUID,
        recipient_id: UUID,
        ciphertext: str,
        nonce: str,
        header: str,
        room_id: str | None = None,
    ) -> Any:
        """
        Stores client-encrypted message in SurrealDB without decrypting it
        """
        sender_user_statement = select(User).where(User.id == sender_id)
        sender_user_result = await session.execute(sender_user_statement)
        sender_user = sender_user_result.scalar_one_or_none()

        if not sender_user:
            raise UserNotFoundError("Sender not found")

        now = datetime.now(UTC)
        surreal_message = {
            "sender_id": str(sender_id),
            "recipient_id": str(recipient_id),
            "room_id": room_id,
            "ciphertext": ciphertext,
            "nonce": nonce,
            "header": header,
            "sender_username": sender_user.username,
            "created_at": now.isoformat(),
            "updated_at": now.isoformat(),
        }

        try:
            result = await surreal_db.create_message(surreal_message)
            logger.info(
                "Stored client-encrypted message: %s -> %s",
                sender_id,
                recipient_id
            )
            return result
        except Exception as e:
            logger.error("Failed to store encrypted message: %s", e)
            raise DatabaseError(f"Failed to store message: {str(e)}") from e


message_service = MessageService()
