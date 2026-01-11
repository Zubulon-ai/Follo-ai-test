#!/usr/bin/env python3
"""
修复 Apple 私钥格式问题
"""

import re


def fix_env_file():
    env_path = ".env"

    # 读取现有 .env 文件
    with open(env_path, "r") as f:
        content = f.read()

    # 检查 APPLE_PRIVATE_KEY 行
    if "APPLE_PRIVATE_KEY" in content:
        print("⚠️  找到 APPLE_PRIVATE_KEY 配置")

        # 检查格式是否正确
        if "\\MIGT" in content:
            print("❌ 发现格式错误：私钥前缀包含反斜杠")

        # 检查私钥长度
        private_key_pattern = r'APPLE_PRIVATE_KEY="(.+?)"'
        match = re.search(private_key_pattern, content, re.DOTALL)

        if match:
            private_key = match.group(1)
            # 计算行数（粗略估计）
            lines = private_key.count("\n")
            print(f"   私钥长度：{len(private_key)} 字符")
            print(f"   粗略行数：{lines}")

            if len(private_key) < 500:
                print("❌ 私钥太短，可能是被截断或格式错误")
                print("\n💡 正确格式应该是：")
                print('   APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----')
                print("   ... 很多行私钥内容 ...")
                print('   -----END PRIVATE KEY-----"')

                print("\n🔧 解决方案：")
                print("1. 从 Apple Developer Portal 下载 .p8 密钥文件")
                print("2. 将 .p8 文件内容粘贴到 .env 中，替换 APPLE_PRIVATE_KEY=")
                print("3. 私钥应该以 '-----BEGIN PRIVATE KEY-----' 开头")

                # 尝试修复反斜杠问题
                print("\n🔨 修复反斜杠问题...")
                content = content.replace(
                    "-----BEGIN PRIVATE KEY-----\\MIGT",
                    "-----BEGIN PRIVATE KEY-----\nMIGT",
                )

                # 写出修复后的文件
                with open(env_path, "w") as f:
                    f.write(content)

                print("✅ 已修复反斜杠问题，但私钥本身可能仍需手动替换")
            else:
                print("✅ 私钥长度看起来正常")


if __name__ == "__main__":
    print("=== Apple 私钥格式检查工具 ===\n")
    fix_env_file()
