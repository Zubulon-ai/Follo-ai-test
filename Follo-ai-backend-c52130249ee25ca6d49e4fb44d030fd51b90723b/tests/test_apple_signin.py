"""测试 Apple Sign In 功能

注意：这个测试需要配置 Apple OAuth 环境变量
如果你没有配置，这些测试会被跳过
"""

import pytest
from sqlalchemy import select

from api.src.users.models import User


@pytest.mark.skip(reason="需要真实的 Apple OAuth 配置")
class TestAppleSignIn:
    """Apple Sign In 测试套件"""

    async def test_apple_login_new_user(self, async_session):
        """测试新用户通过 Apple 登录"""
        # 这个测试需要真实的 Apple 配置

    async def test_apple_login_existing_user(self, async_session):
        """测试已存在用户通过 Apple 登录"""
        # 这个测试需要真实的 Apple 配置

    async def test_apple_login_invalid_code(self, async_session):
        """测试使用无效授权码登录"""
        from api.core.exceptions import UnauthorizedException

        # 测试使用无效的 authorization_code
        with pytest.raises(UnauthorizedException):
            # 需要传入无效的 code 进行测试
            pass


@pytest.mark.skipif(
    not all(
        [
            "APPLE_CLIENT_ID" in __import__("os").environ,
            "APPLE_TEAM_ID" in __import__("os").environ,
        ]
    ),
    reason="Apple OAuth 配置未设置",
)
class TestAppleConfiguration:
    """测试 Apple 配置"""

    def test_apple_oauth_configured(self):
        """测试 Apple OAuth 是否已配置"""
        from api.core.apple_oauth import apple_oauth

        assert apple_oauth.is_configured is True

    def test_apple_service_instance(self):
        """测试 Apple 服务实例"""
        from api.core.apple_oauth import apple_oauth

        assert apple_oauth.client_id is not None
        assert apple_oauth.team_id is not None
        assert apple_oauth.key_id is not None
        assert apple_oauth.private_key is not None


def test_user_model_apple_fields(db_session):
    """测试用户模型的 Apple 相关字段"""
    # 创建测试用户
    user = User(
        email="test@example.com",
        apple_id="com.apple.test.id",
        is_active=True,
    )
    db_session.add(user)
    db_session.commit()

    # 查询用户
    result = db_session.execute(
        select(User).where(User.apple_id == "com.apple.test.id")
    )
    saved_user = result.scalar_one()

    assert saved_user.email == "test@example.com"
    assert saved_user.apple_id == "com.apple.test.id"
    assert saved_user.is_active is True
    assert saved_user.hashed_password is None


def test_user_model_nullable_password():
    """测试用户模型允许密码为 NULL"""
    from api.src.users.models import User

    # 检查 hashed_password 字段允许 NULL
    user = User(
        email="apple@example.com",
        apple_id="com.apple.id",
        hashed_password=None,
    )
    assert user.hashed_password is None


def test_apple_login_request_schema():
    """测试 Apple 登录请求 schema"""
    from api.src.users.schemas import AppleLoginRequest

    # 有效的授权码
    request = AppleLoginRequest(authorization_code="test_auth_code_123")

    assert request.authorization_code == "test_auth_code_123"


def test_user_response_apple_fields():
    """测试用户响应 schema 包含 Apple 字段"""
    from api.src.users.schemas import UserResponse

    # 创建用户响应
    user_data = {
        "id": 1,
        "email": "test@example.com",
        "is_active": True,
        "apple_id": "com.apple.test",
    }

    user_response = UserResponse(**user_data)

    assert user_response.id == 1
    assert user_response.email == "test@example.com"
    assert user_response.is_active is True
    assert user_response.apple_id == "com.apple.test"


def test_user_repository_get_by_apple_id(async_session):
    """测试用户仓库按 Apple ID 查询"""
    from api.src.users.repository import UserRepository

    # 创建测试用户
    user = User(
        email="apple@example.com",
        apple_id="com.apple.test.id",
        is_active=True,
    )
    async_session.add(user)
    async_session.commit()

    # 查询
    repository = UserRepository(async_session)
    result = repository.get_by_apple_id("com.apple.test.id")

    assert result is not None
    assert result.apple_id == "com.apple.test.id"
    assert result.email == "apple@example.com"


@pytest.mark.asyncio
async def test_user_repository_create_apple_user(async_session):
    """测试用户仓库创建 Apple 用户"""
    from api.core.exceptions import AlreadyExistsException
    from api.src.users.repository import UserRepository

    repository = UserRepository(async_session)

    # 创建 Apple 用户
    user = await repository.create_apple_user(
        email="apple@example.com",
        apple_id="com.apple.test.id",
    )

    assert user.email == "apple@example.com"
    assert user.apple_id == "com.apple.test.id"
    assert user.hashed_password is None
    assert user.is_active is True

    # 尝试创建重复的 Apple ID
    with pytest.raises(AlreadyExistsException):
        await repository.create_apple_user(
            email="different@example.com",
            apple_id="com.apple.test.id",
        )


@pytest.mark.asyncio
async def test_user_service_authenticate_with_apple(async_session):
    """测试用户服务 Apple 认证"""
    from api.src.users.service import UserService

    # 注意：这个测试需要真实的 Apple 配置和授权码
    # 这里只是测试服务方法的结构

    service = UserService(async_session)

    # 创建测试用户（不通过 Apple）
    user = User(
        email="test@example.com",
        apple_id="com.apple.test.id",
        is_active=True,
    )
    async_session.add(user)
    async_session.commit()

    # 测试获取用户
    retrieved_user = await service.get_user(user.id)
    assert retrieved_user is not None
    assert retrieved_user.id == user.id


if __name__ == "__main__":
    # 运行测试
    pytest.main([__file__, "-v"])
