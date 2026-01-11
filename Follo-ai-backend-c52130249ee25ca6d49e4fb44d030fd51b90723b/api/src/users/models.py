from sqlalchemy import Boolean, Column, Integer, String

from api.core.database import Base


class User(Base):
    """User model."""

    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    email = Column(
        String, unique=True, index=True, nullable=True
    )  # 允许为空（Apple 登录用户）
    hashed_password = Column(String, nullable=True)  # 允许为空（Apple 登录用户）
    apple_id = Column(String, unique=True, index=True, nullable=True)
    is_active = Column(Boolean, default=True)
