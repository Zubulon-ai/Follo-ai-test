from datetime import timedelta

from sqlalchemy.ext.asyncio import AsyncSession

from api.core.apple_oauth import apple_oauth
from api.core.config import settings
from api.core.exceptions import UnauthorizedException
from api.core.logging import get_logger
from api.core.security import (
    create_access_token,
    create_refresh_token,
    verify_password,
    verify_refresh_token,
)
from api.src.users.models import User
from api.src.users.repository import UserRepository
from api.src.users.schemas import AppleLoginRequest, LoginData, Token, UserCreate

logger = get_logger(__name__)


class UserService:
    """Service for handling user business logic."""

    def __init__(self, session: AsyncSession):
        self.session = session
        self.repository = UserRepository(session)

    async def create_user(self, user_data: UserCreate) -> User:
        """Create a new user."""
        return await self.repository.create(user_data)

    async def authenticate(self, login_data: LoginData) -> Token:
        """Authenticate user and return token."""
        # Get user
        user = await self.repository.get_by_email(login_data.email)

        # Verify credentials
        if not user or not verify_password(
            login_data.password, str(user.hashed_password)
        ):
            raise UnauthorizedException(detail="Incorrect email or password")

        # Create access token and refresh token
        access_token = create_access_token(
            data={"sub": str(user.id)},
            expires_delta=timedelta(minutes=settings.JWT_EXPIRATION),
        )
        refresh_token = create_refresh_token(data={"sub": str(user.id)})

        logger.info(f"User authenticated: {user.email}")
        return Token(access_token=access_token, refresh_token=refresh_token)

    async def authenticate_with_apple(self, apple_data: AppleLoginRequest) -> Token:
        """Authenticate user via Apple Sign In."""
        # 验证 Apple 授权码
        apple_user_info = await apple_oauth.verify_authorization_code(
            apple_data.authorization_code
        )

        if not apple_user_info:
            raise UnauthorizedException(detail="Invalid Apple authorization code")

        apple_id = apple_user_info["apple_id"]
        email = apple_user_info.get("email")

        # 查找是否已有使用此 Apple ID 的用户
        user = await self.repository.get_by_apple_id(apple_id)

        if user:
            # 用户已存在，更新邮箱（如果需要）
            if email and user.email != email:
                user.email = email
                await self.session.commit()

            logger.info(f"Apple user authenticated: {user.email}")
        else:
            # 新用户，创建账户
            # Apple Sign In 允许没有邮箱的账户（Apple ID 作为唯一标识）
            user = await self.repository.create_apple_user(
                email=email,  # 可以为 None
                apple_id=apple_id,
                is_active=True,
            )

            logger.info(f"New Apple user created: {user.email or 'No email provided'}")

        # 检查用户是否被禁用
        if not user.is_active:
            raise UnauthorizedException(detail="User account is disabled")

        # 创建访问令牌和刷新令牌
        access_token = create_access_token(
            data={"sub": str(user.id)},
            expires_delta=timedelta(minutes=settings.JWT_EXPIRATION),
        )
        refresh_token = create_refresh_token(data={"sub": str(user.id)})

        return Token(access_token=access_token, refresh_token=refresh_token)

    async def link_apple_account(
        self, user_id: int, apple_data: AppleLoginRequest
    ) -> User:
        """将现有账户与 Apple ID 关联"""
        # 验证 Apple 授权码
        apple_user_info = await apple_oauth.verify_authorization_code(
            apple_data.authorization_code
        )

        if not apple_user_info:
            raise UnauthorizedException(detail="Invalid Apple authorization code")

        apple_id = apple_user_info["apple_id"]

        # 关联 Apple 账户
        user = await self.repository.link_apple_account(user_id, apple_id)

        logger.info(f"Apple account linked: User ID {user.id}")
        return user

    async def get_user(self, user_id: int) -> User:
        """Get user by ID."""
        return await self.repository.get_by_id(user_id)

    async def refresh_tokens(self, refresh_token_str: str) -> Token:
        """Refresh access token using refresh token."""
        payload = verify_refresh_token(refresh_token_str)
        if not payload:
            raise UnauthorizedException(detail="Invalid refresh token")

        user_id = payload.get("sub")
        if not user_id:
            raise UnauthorizedException(detail="Invalid refresh token")

        # Verify user exists
        user = await self.repository.get_by_id(int(user_id))
        if not user:
            raise UnauthorizedException(detail="User not found")

        if not user.is_active:
            raise UnauthorizedException(detail="User account is disabled")

        # Create new tokens
        access_token = create_access_token(
            data={"sub": str(user.id)},
            expires_delta=timedelta(minutes=settings.JWT_EXPIRATION),
        )
        new_refresh_token = create_refresh_token(data={"sub": str(user.id)})

        logger.info(f"Tokens refreshed for user: {user.id}")
        return Token(access_token=access_token, refresh_token=new_refresh_token)
