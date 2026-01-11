from typing import Annotated

from fastapi import APIRouter, Depends, status
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.database import get_session
from api.core.logging import get_logger
from api.core.security import get_current_user
from api.src.users.models import User
from api.src.users.schemas import (
    AppleLoginRequest,
    LoginData,
    RefreshTokenRequest,
    Token,
    UserCreate,
    UserResponse,
)
from api.src.users.service import UserService

logger = get_logger(__name__)

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post(
    "/register", response_model=UserResponse, status_code=status.HTTP_201_CREATED
)
async def register(
    user_data: UserCreate, session: AsyncSession = Depends(get_session)
) -> UserResponse:
    """Register a new user."""
    logger.debug(f"Registering user: {user_data.email}")
    return await UserService(session).create_user(user_data)


@router.post("/login", response_model=Token)
async def login(
    form_data: Annotated[OAuth2PasswordRequestForm, Depends()],
    session: AsyncSession = Depends(get_session),
) -> Token:
    """Authenticate user and return token."""
    login_data = LoginData(email=form_data.username, password=form_data.password)
    logger.debug(f"Login attempt: {login_data.email}")
    return await UserService(session).authenticate(login_data)


@router.post("/apple-login", response_model=Token)
async def apple_login(
    apple_data: AppleLoginRequest,
    session: AsyncSession = Depends(get_session),
) -> Token:
    """Authenticate user via Apple Sign In."""
    logger.debug("Apple Sign In attempt")
    return await UserService(session).authenticate_with_apple(apple_data)


@router.post("/link-apple", response_model=UserResponse)
async def link_apple_account(
    apple_data: AppleLoginRequest,
    current_user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
) -> UserResponse:
    """Link current user account with Apple ID."""
    logger.debug(f"Linking Apple account for user: {current_user.id}")
    return await UserService(session).link_apple_account(current_user.id, apple_data)


@router.get("/me", response_model=UserResponse)
async def get_me(user: User = Depends(get_current_user)) -> UserResponse:
    """Get current authenticated user."""
    return user


@router.post("/token/refresh", response_model=Token)
async def refresh_token(
    refresh_data: RefreshTokenRequest,
    session: AsyncSession = Depends(get_session),
) -> Token:
    """Refresh access token using refresh token."""
    logger.debug("Token refresh attempt")
    return await UserService(session).refresh_tokens(refresh_data.refresh_token)


@router.get("/check-apple/{apple_id}", response_model=dict)
async def check_apple_id(
    apple_id: str,
    session: AsyncSession = Depends(get_session),
) -> dict:
    """Check if an Apple ID is already linked to an account."""
    user_service = UserService(session)
    user = await user_service.repository.get_by_apple_id(apple_id)
    return {"is_linked": user is not None, "user_id": user.id if user else None}


@router.get("/check-email/{email}", response_model=dict)
async def check_email(email: str, session: AsyncSession = Depends(get_session)) -> dict:
    """Check if an email is already registered."""
    user_service = UserService(session)
    user = await user_service.repository.get_by_email(email)
    return {"is_registered": user is not None, "user_id": user.id if user else None}
