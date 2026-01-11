from pydantic import BaseModel, ConfigDict, EmailStr


class UserBase(BaseModel):
    """Base user schema."""

    email: EmailStr | None = None  # 可以为 None（Apple 登录用户）


class UserCreate(UserBase):
    """User creation schema."""

    password: str


class AppleLoginRequest(BaseModel):
    """Apple 登录请求"""

    authorization_code: str


class UserResponse(UserBase):
    """User response schema."""

    model_config = ConfigDict(from_attributes=True)
    id: int
    is_active: bool = True
    apple_id: str | None = None


class Token(BaseModel):
    """Token schema."""

    access_token: str
    refresh_token: str
    token_type: str = "bearer"


class RefreshTokenRequest(BaseModel):
    """Refresh token request schema."""

    refresh_token: str


class LoginData(BaseModel):
    """Login data schema."""

    email: EmailStr
    password: str


class AppleUserResponse(BaseModel):
    """Apple user response schema."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    email: EmailStr | None = None
    is_active: bool = True
    apple_id: str | None = None
