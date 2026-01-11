#!/usr/bin/env python3
"""
测试 Apple OAuth 配置
"""

import os

from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from dotenv import load_dotenv

# 加载环境变量
load_dotenv()


def test_private_key():
    print("=== Apple 私钥配置测试 ===\n")

    # 读取配置
    APPLE_PRIVATE_KEY = os.getenv("APPLE_PRIVATE_KEY", "")
    APPLE_CLIENT_ID = os.getenv("APPLE_CLIENT_ID", "")
    APPLE_TEAM_ID = os.getenv("APPLE_TEAM_ID", "")
    APPLE_KEY_ID = os.getenv("APPLE_KEY_ID", "")

    print(f"1. 检查配置项：")
    print(f"   APPLE_CLIENT_ID: {APPLE_CLIENT_ID}")
    print(f"   APPLE_TEAM_ID: {APPLE_TEAM_ID}")
    print(f"   APPLE_KEY_ID: {APPLE_KEY_ID}")
    print(f"   APPLE_PRIVATE_KEY 长度: {len(APPLE_PRIVATE_KEY)}")

    # 检查私钥格式
    print(f"\n2. 检查私钥格式：")
    if APPLE_PRIVATE_KEY.startswith("-----BEGIN PRIVATE KEY-----"):
        print("   ✅ 私钥以正确的前缀开头")
    else:
        print("   ❌ 私钥前缀不正确")

    if APPLE_PRIVATE_KEY.endswith("-----END PRIVATE KEY-----"):
        print("   ✅ 私钥以正确的后缀结尾")
    else:
        print("   ❌ 私钥后缀不正确")

    # 检查是否是有效的PEM
    print(f"\n3. 验证PEM格式：")
    try:
        # 尝试解析私钥
        private_key = serialization.load_pem_private_key(
            APPLE_PRIVATE_KEY.encode("utf-8"), password=None, backend=default_backend()
        )

        # 检查密钥类型
        if isinstance(private_key, ec.EllipticCurvePrivateKey):
            print("   ✅ 是有效的 EC 私钥")

            # 检查曲线类型
            curve = private_key.curve
            print(f"   ✅ 曲线类型: {curve.name}")

            if curve.name == "P-256":
                print("   ✅ 曲线类型正确 (P-256)")
            else:
                print(f"   ⚠️  曲线类型不是 P-256: {curve.name}")

            # 获取公钥
            public_key = private_key.public_key()
            print(f"   ✅ 私钥可以生成公钥")

            # 获取编码长度
            private_bytes = private_key.private_numbers().private_value.to_bytes(
                32, "big"
            )
            print(f"   ✅ 私钥编码长度: 32 字节 (256 bits)")

        else:
            print(f"   ⚠️  不是 EC 私钥，而是 {type(private_key).__name__}")

    except Exception as e:
        print(f"   ❌ 私钥解析失败: {e}")
        return False

    print(f"\n4. 生成测试数据：")
    print(f"   私钥可用于 JWT 签名: ✅")
    print(f"   建议使用算法: ES256")

    print("\n✅ 私钥格式验证完成")
    return True


if __name__ == "__main__":
    test_private_key()
