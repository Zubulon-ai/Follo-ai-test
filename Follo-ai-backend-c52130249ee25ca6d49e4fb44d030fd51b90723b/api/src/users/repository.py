from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.exceptions import AlreadyExistsException, NotFoundException
from api.core.logging import get_logger
from api.core.security import get_password_hash
from api.src.users.models import User
from api.src.users.schemas import UserCreate

logger = get_logger(__name__)


class UserRepository:
    """Repository for handling user database operations."""

    def __init__(self, session: AsyncSession):
        self.session = session

    async def create(self, user_data: UserCreate) -> User:
        """Create a new user.

        Args:
            user_data: User creation data

        Returns:
            User: Created user

        Raises:
            AlreadyExistsException: If user with same email already exists
        """
        # Check if user exists
        existing_user = await self.get_by_email(user_data.email)
        if existing_user:
            raise AlreadyExistsException("Email already registered")

        # Create user
        user = User(
            email=user_data.email, hashed_password=get_password_hash(user_data.password)
        )
        self.session.add(user)
        await self.session.commit()
        await self.session.refresh(user)

        logger.info(f"Created user: {user.email}")
        return user

    async def get_by_id(self, user_id: int) -> User:
        """Get user by ID.

        Args:
            user_id: User ID

        Returns:
            User: Found user

        Raises:
            NotFoundException: If user not found
        """
        query = select(User).where(User.id == user_id)
        result = await self.session.execute(query)
        user = result.scalar_one_or_none()

        if not user:
            raise NotFoundException("User not found")

        return user

    async def get_by_email(self, email: str) -> User | None:
        """Get user by email.

        Args:
            email: User email

        Returns:
            Optional[User]: Found user or None if not found
        """
        query = select(User).where(User.email == email)
        result = await self.session.execute(query)
        return result.scalar_one_or_none()

    async def get_by_apple_id(self, apple_id: str) -> User | None:
        """Get user by Apple ID.

        Args:
            apple_id: Apple user ID (sub)

        Returns:
            Optional[User]: Found user or None if not found
        """
        query = select(User).where(User.apple_id == apple_id)
        result = await self.session.execute(query)
        return result.scalar_one_or_none()

    async def create_apple_user(
        self, email: str | None, apple_id: str, is_active: bool = True
    ) -> User:
        """Create user via Apple Sign In.

        Args:
            email: User email (from Apple) - can be None
            apple_id: Apple user ID
            is_active: User active status

        Returns:
            User: Created user

        Raises:
            AlreadyExistsException: If Apple ID or email already exists
        """
        # 检查 Apple ID 是否存在
        existing_apple_user = await self.get_by_apple_id(apple_id)
        if existing_apple_user:
            raise AlreadyExistsException("Apple ID already registered")

        # 检查邮箱是否已存在（仅当email不为None时）
        if email:
            existing_email_user = await self.get_by_email(email)
            if existing_email_user:
                raise AlreadyExistsException("Email already registered")

        # 创建用户
        user = User(
            email=email,
            apple_id=apple_id,
            hashed_password=None,  # Apple 登录用户没有密码
            is_active=is_active,
        )
        self.session.add(user)
        await self.session.commit()
        await self.session.refresh(user)

        logger.info(
            f"Created Apple user: {user.email or 'No email'}, Apple ID: {user.apple_id}"
        )
        return user

    async def link_apple_account(self, user_id: int, apple_id: str) -> User:
        """Link existing user account with Apple ID.

        Args:
            user_id: User ID
            apple_id: Apple user ID

        Returns:
            User: Updated user

        Raises:
            AlreadyExistsException: If Apple ID is already linked
            NotFoundException: If user not found
        """
        # 检查 Apple ID 是否已被使用
        existing_apple_user = await self.get_by_apple_id(apple_id)
        if existing_apple_user:
            raise AlreadyExistsException("Apple ID already linked to another account")

        # 获取用户
        user = await self.get_by_id(user_id)

        # 更新 Apple ID
        user.apple_id = apple_id
        await self.session.commit()
        await self.session.refresh(user)

        logger.info(f"Linked Apple account: User ID {user.id}, Apple ID {apple_id}")
        return user
