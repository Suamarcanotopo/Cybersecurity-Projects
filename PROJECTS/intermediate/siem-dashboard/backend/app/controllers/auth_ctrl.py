"""
©AngelaMos | 2026
auth_ctrl.py

Business logic for authentication operations

Handles user registration with uniqueness checks, timing-safe login
with Argon2 param rehashing on success, self-service profile updates
confirmed by current password, and the /me identity endpoint.

Key exports:
  register, login, update_profile, me

Connects to:
  core/auth.py - hash_password, verify_password, create_access_token
  core/errors.py - raises ConflictError, AuthenticationError, ValidationError
  models/User.py - find_by_username, create_user, username_exists
  schemas/auth.py - instantiates TokenResponse, UserResponse, UpdateProfileResponse
  routes/auth.py - called from route handlers
"""

from typing import Any

from flask import g

from app.core.auth import (
    hash_password,
    verify_password,
    verify_password_timing_safe,
    create_access_token,
)
from app.core.errors import ConflictError, AuthenticationError, ValidationError
from app.models.User import User
from app.schemas.auth import TokenResponse, UserResponse, UpdateProfileResponse


def register() -> dict[str, Any]:
    """
    Register a new analyst account
    """
    data = g.validated

    if User.username_exists(data.username):
        raise ConflictError("Username already taken")
    if User.email_exists(data.email):
        raise ConflictError("Email already registered")

    hashed = hash_password(data.password)
    user = User.create_user(
        username = data.username,
        email = data.email,
        password_hash = hashed,
    )

    token = create_access_token(
        user_id = str(user.id),
        extra_claims = {
            "username": user.username,
            "role": user.role,
        },
    )
    return TokenResponse(
        access_token = token,
    ).model_dump()


def login() -> dict[str, Any]:
    """
    Authenticate and return a JWT
    """
    data = g.validated

    user = User.find_by_username(data.username)
    existing_hash = user.password_hash if user else None
    is_valid, new_hash = verify_password_timing_safe(data.password, existing_hash)

    if not is_valid or user is None:
        raise AuthenticationError("Invalid username or password")

    if not user.is_active:
        raise AuthenticationError("Account is deactivated")

    if new_hash:
        user.password_hash = new_hash
        user.save()

    token = create_access_token(
        user_id = str(user.id),
        extra_claims = {
            "username": user.username,
            "role": user.role,
        },
    )
    return TokenResponse(
        access_token = token,
    ).model_dump()


def update_profile() -> dict[str, Any]:
    """
    Update the authenticated user's own profile fields
    """
    user = g.current_user
    data = g.validated

    is_valid, _ = verify_password(data.current_password, user.password_hash)
    if not is_valid:
        raise AuthenticationError("Current password is incorrect")

    updates: dict[str, str] = {}

    if data.username is not None and data.username != user.username:
        if User.username_exists(data.username):
            raise ConflictError("Username already taken")
        updates["username"] = data.username

    if data.email is not None and data.email != user.email:
        if User.email_exists(data.email):
            raise ConflictError("Email already registered")
        updates["email"] = data.email

    if data.password is not None:
        updates["password_hash"] = hash_password(data.password)

    if not updates:
        raise ValidationError("No fields to update")

    user.update_profile(**updates)

    new_token: str | None = None
    if "username" in updates:
        new_token = create_access_token(
            user_id = str(user.id),
            extra_claims = {
                "username": user.username,
                "role": user.role,
            },
        )

    return UpdateProfileResponse(
        user = UserResponse(
            id = str(user.id),
            username = user.username,
            email = user.email,
            role = user.role,
            is_active = user.is_active,
        ),
        access_token = new_token,
    ).model_dump(exclude_none = True)


def me() -> dict[str, Any]:
    """
    Return the current authenticated user profile
    """
    user = g.current_user
    return UserResponse(
        id = str(user.id),
        username = user.username,
        email = user.email,
        role = user.role,
        is_active = user.is_active,
    ).model_dump()
