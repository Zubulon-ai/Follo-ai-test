"""Apple OAuth 2.0 验证工具"""

import base64
import json
import time
from typing import Dict, Optional

import httpx
from jose import jwt

from api.core.config import settings


class AppleOAuthService:
    """Apple OAuth 2.0 服务"""

    def __init__(self):
        self.client_id = settings.APPLE_CLIENT_ID
        self.team_id = settings.APPLE_TEAM_ID
        self.key_id = settings.APPLE_KEY_ID
        self.private_key = settings.APPLE_PRIVATE_KEY
        self.apple_auth_url = "https://appleid.apple.com"
        self.token_endpoint = f"{self.apple_auth_url}/auth/token"

        # 检查配置是否完整
        if not all([self.client_id, self.team_id, self.key_id, self.private_key]):
            self.is_configured = False
        else:
            self.is_configured = True

    def _create_client_secret(self) -> str:
        """创建客户端密钥 (JWT)"""
        now = int(time.time())

        # JWT Header
        header = {
            "alg": "ES256",  # Apple 要求使用 ES256
            "kid": self.key_id,
        }

        # JWT Payload
        payload = {
            "iss": self.team_id,
            "iat": now,
            "exp": now + 3600,  # 1小时过期
            "aud": self.apple_auth_url,
            "sub": self.client_id,
        }

        # 生成 JWT token
        try:
            print(f"准备创建JWT client secret...")
            print(f"  - Team ID: {self.team_id}")
            print(f"  - Key ID: {self.key_id}")
            print(f"  - Client ID: {self.client_id}")
            print(f"  - Audience: {self.apple_auth_url}")
            print(f"  - 私钥长度: {len(self.private_key)}")
            print(f"  - 私钥前缀: {self.private_key[:30]}...")

            client_secret = jwt.encode(
                payload,
                self.private_key,
                algorithm="ES256",
                headers=header,
            )

            print(f"✅ JWT client secret 创建成功，长度: {len(client_secret)}")
            return client_secret

        except Exception as e:
            print(f"❌ 创建客户端密钥失败: {e}")
            print(f"   错误类型: {type(e).__name__}")
            print(f"   私钥内容预览: {self.private_key[:50]}...")
            print(f"   私钥格式检查:")
            print(
                f"     - 以 '-----BEGIN' 开头: {self.private_key.startswith('-----BEGIN')}"
            )
            print(f"     - 以 '-----END' 结尾: {self.private_key.endswith('-----END')}")
            print(
                f"     - 包含换行符: {chr(10) in self.private_key or '\\n' in self.private_key}"
            )

            # 尝试加载密钥以获取更详细的错误信息
            try:
                from cryptography.hazmat.backends import default_backend
                from cryptography.hazmat.primitives import serialization

                key = serialization.load_pem_private_key(
                    self.private_key.encode("utf-8"),
                    password=None,
                    backend=default_backend(),
                )
                print(f"   私钥可以正常加载为 cryptography 对象")
            except Exception as load_error:
                print(f"   ❌ 私钥加载也失败: {load_error}")

            raise

    async def verify_authorization_code(
        self, authorization_code: str
    ) -> Optional[Dict]:
        """验证授权码并获取用户信息"""

        # 检查是否已配置
        if not self.is_configured:
            raise ValueError("Apple OAuth is not configured")

        client_secret = self._create_client_secret()

        # 请求参数
        data = {
            "grant_type": "authorization_code",
            "code": authorization_code,
            "client_id": self.client_id,
            "client_secret": client_secret,
        }

        headers = {
            "Content-Type": "application/x-www-form-urlencoded",
        }

        async with httpx.AsyncClient() as client:
            try:
                response = await client.post(
                    self.token_endpoint,
                    data=data,
                    headers=headers,
                    timeout=10.0,
                )

                if response.status_code != 200:
                    return None

                token_data = response.json()

                # 解析 id_token 获取用户信息
                id_token = token_data.get("id_token")
                if not id_token:
                    return None

                print(f"获取到id_token，长度: {len(id_token)}")

                # 手动解码JWT payload（不验证signature）
                try:
                    # JWT格式: header.payload.signature
                    parts = id_token.split(".")
                    if len(parts) != 3:
                        print(f"❌ id_token格式错误，分段数: {len(parts)}")
                        return None

                    # 解码payload (第2段)
                    payload = parts[1]

                    # 添加必要的填充
                    padding = len(payload) % 4
                    if padding:
                        payload += "=" * (4 - padding)

                    decoded_bytes = base64.urlsafe_b64decode(payload)
                    decoded = json.loads(decoded_bytes)

                    print(f"✅ 成功解码id_token payload")
                    print(f"   Apple ID: {decoded.get('sub')}")
                    print(f"   Email: {decoded.get('email')}")

                except Exception as decode_error:
                    print(f"❌ 解码id_token失败: {decode_error}")
                    return None

                return {
                    "apple_id": decoded.get("sub"),
                    "email": decoded.get("email"),
                    "is_email_verified": decoded.get("email_verified"),
                    "is_real_email": decoded.get("is_private_email"),
                    "access_token": token_data.get("access_token"),
                    "refresh_token": token_data.get("refresh_token"),
                }

            except Exception as e:
                print(f"Apple OAuth error: {e}")
                return None

    async def refresh_access_token(self, refresh_token: str) -> Optional[Dict]:
        """刷新访问令牌"""

        # 检查是否已配置
        if not self.is_configured:
            raise ValueError("Apple OAuth is not configured")

        client_secret = self._create_client_secret()

        data = {
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": self.client_id,
            "client_secret": client_secret,
        }

        headers = {
            "Content-Type": "application/x-www-form-urlencoded",
        }

        async with httpx.AsyncClient() as client:
            try:
                response = await client.post(
                    self.token_endpoint,
                    data=data,
                    headers=headers,
                    timeout=10.0,
                )

                if response.status_code != 200:
                    return None

                return response.json()

            except Exception as e:
                print(f"Apple token refresh error: {e}")
                return None


# 单例实例
apple_oauth = AppleOAuthService()
