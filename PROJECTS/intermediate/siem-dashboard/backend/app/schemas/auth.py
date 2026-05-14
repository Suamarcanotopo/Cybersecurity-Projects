"""
©AngelaMos | 2026
auth.py

Pydantic schemas for authentication endpoints

Defines request and response models for registration, login, and
self-service profile updates. USERNAME_MIN and USERNAME_MAX are
imported from the User model so validation constraints stay in
sync with the database layer.

Key exports:
  RegisterRequest, LoginRequest, UpdateProfileRequest - request schemas
  TokenResponse, UserResponse, UpdateProfileResponse - response schemas

Connects to:
  models/User.py - imports USERNAME_MIN, USERNAME_MAX
  controllers/auth_ctrl.py, controllers/admin_ctrl.py - instantiates response schemas
  routes/auth.py - passed to S()
"""

from pydantic import BaseModel, EmailStr, Field

from app.models.User import USERNAME_MIN, USERNAME_MAX


PASSWORD_MIN = 8


class RegisterRequest(BaseModel):
    """
    Schema for user registration
    """
    username: str = Field(
        min_length = USERNAME_MIN,
        max_length = USERNAME_MAX,
    )
    email: EmailStr
    password: str = Field(min_length = PASSWORD_MIN)


class LoginRequest(BaseModel):
    """
    Schema for user login
    """
    username: str
    password: str


class TokenResponse(BaseModel):
    """
    JWT token returned after login or registration
    """
    access_token: str
    token_type: str = "bearer"


class UpdateProfileRequest(BaseModel):
    """
    Self-service profile update validated by current password
    """
    current_password: str
    username: str | None = Field(
        default = None,
        min_length = USERNAME_MIN,
        max_length = USERNAME_MAX,
    )
    email: EmailStr | None = None
    password: str | None = Field(default = None, min_length = PASSWORD_MIN)


class UserResponse(BaseModel):
    """
    Public user profile data
    """
    id: str
    username: str
    email: str
    role: str
    is_active: bool


class UpdateProfileResponse(BaseModel):
    """
    Updated profile with an optional refreshed token
    """
    user: UserResponse
    access_token: str | None = None
    token_type: str = "bearer"
