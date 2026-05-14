"""
©AngelaMos | 2026
conftest.py
"""

import asyncio
import secrets
from collections.abc import AsyncGenerator

import pytest
import pytest_asyncio
from sqlmodel import SQLModel
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    create_async_engine,
)
from sqlalchemy.orm import sessionmaker

from app.models.User import User


@pytest.fixture(scope = "session")
def event_loop():
    """
    Create event loop for async tests
    """
    loop = asyncio.get_event_loop_policy().new_event_loop()
    yield loop
    loop.close()


@pytest_asyncio.fixture(scope = "function")
async def db_session() -> AsyncGenerator[AsyncSession]:
    """
    Create in-memory SQLite database for testing
    """
    engine = create_async_engine(
        "sqlite+aiosqlite:///:memory:",
        echo = False,
        future = True,
    )

    async with engine.begin() as conn:
        await conn.run_sync(SQLModel.metadata.create_all)

    async_session = sessionmaker(
        bind = engine,
        class_ = AsyncSession,
        expire_on_commit = False,
    )

    async with async_session() as session:
        yield session
        await session.rollback()

    await engine.dispose()


@pytest_asyncio.fixture
async def test_user(db_session: AsyncSession) -> User:
    """
    Create test user
    """
    user = User(
        username = "testuser",
        display_name = "Test User",
        is_active = True,
        is_verified = True,
        webauthn_user_handle = secrets.token_bytes(64),
    )
    db_session.add(user)
    await db_session.commit()
    await db_session.refresh(user)
    return user


@pytest_asyncio.fixture
async def test_user_2(db_session: AsyncSession) -> User:
    """
    Create second test user for conversations
    """
    user = User(
        username = "testuser2",
        display_name = "Test User 2",
        is_active = True,
        is_verified = True,
        webauthn_user_handle = secrets.token_bytes(64),
    )
    db_session.add(user)
    await db_session.commit()
    await db_session.refresh(user)
    return user
