# 🍎 Apple Sign In 集成指南

## 📋 概述

本指南将帮助你为后端 API 集成 Apple Sign In 功能。Apple Sign In 允许用户使用他们的 Apple ID 登录你的应用，提供更安全、便捷的身份验证体验。

## 🔧 配置步骤

### 1. Apple Developer 配置

在开始之前，你需要在 Apple Developer 账户中配置 Sign in with Apple：

1. 登录 [Apple Developer Portal](https://developer.apple.com/)
2. 导航到 Certificates, Identifiers & Profiles > Identifiers
3. 创建或选择一个 App ID
4. 启用 "Sign in with Apple" 能力
5. 创建一个 Services ID（用作 client_id）
6. 为该 Services ID 配置 "Sign in with Apple"
7. 创建并下载一个 Sign in with Apple 密钥
8. 记录以下信息：
   - **Team ID** (在 Apple Developer 账户设置中找到)
   - **Key ID** (从密钥中获取)
   - **Services ID** (你创建的 Services ID)
   - **Private Key** (下载的 .p8 文件内容)

### 2. 环境变量配置

复制示例环境变量文件并填入你的 Apple 配置：

```bash
cp .env.example .env
```

编辑 `.env` 文件，填入你的 Apple 配置：

```bash
DATABASE_URL=postgresql+asyncpg://user:pass@localhost:5432/dbname
JWT_SECRET=your-jwt-secret-key

# Apple Sign In 配置
APPLE_CLIENT_ID=com.yourcompany.yourapp  # 你的 Services ID
APPLE_TEAM_ID=YOUR_TEAM_ID               # 你的 Team ID
APPLE_KEY_ID=YOUR_KEY_ID                 # 你的 Key ID
APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\nYOUR_PRIVATE_KEY_CONTENT\n-----END PRIVATE KEY-----"
```

**⚠️ 重要提示：**
- `APPLE_PRIVATE_KEY` 中的换行符需要使用 `\n` 转义
- 确保引号正确包含整个私钥内容
- 生产环境中请使用更强的 JWT_SECRET

### 3. 数据库迁移

运行数据库迁移以添加 Apple 登录所需的字段：

```bash
# 如果你还没有数据库，先创建
createdb your_db_name

# 运行迁移
uv run alembic upgrade head
```

这将：
- 在 `users` 表中添加 `apple_id` 字段
- 在 `users` 表中添加 `is_active` 字段
- 允许 `hashed_password` 为 NULL（Apple 登录用户不需要密码）

### 4. 启动服务

```bash
uv run uvicorn api.main:app --reload
```

## 🔌 API 端点

Apple Sign In 提供以下 API 端点：

### 1. Apple 登录
```http
POST /auth/apple-login
Content-Type: application/json

{
    "authorization_code": "Apple 返回的 authorization code"
}
```

**响应：**
```json
{
    "access_token": "your-jwt-token",
    "token_type": "bearer"
}
```

### 2. 关联现有账户与 Apple ID
```http
POST /auth/link-apple
Authorization: Bearer your-jwt-token
Content-Type: application/json

{
    "authorization_code": "Apple 返回的 authorization code"
}
```

**响应：**
```json
{
    "id": 1,
    "email": "user@example.com",
    "is_active": true,
    "apple_id": "com.apple.user.id"
}
```

### 3. 检查 Apple ID 是否已关联
```http
GET /auth/check-apple/{apple_id}
```

**响应：**
```json
{
    "is_linked": true,
    "user_id": 1
}
```

### 4. 检查邮箱是否已注册
```http
GET /auth/check-email/{email}
```

**响应：**
```json
{
    "is_registered": true,
    "user_id": 1
}
```

## 📱 移动端集成

### iOS Swift 示例

```swift
import AuthenticationServices

class AppleSignInManager: NSObject, ASAuthorizationControllerDelegate {
    func appleLogin() {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = UUID().uuidString

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential {
            guard let authorizationCode = appleIDCredential.authorizationCode else { return }

            // 将 authorization code 发送到后端
            let codeString = String(data: authorizationCode, encoding: .utf8)!
            sendCodeToBackend(authorizationCode: codeString)
        }
    }

    private func sendCodeToBackend(authorizationCode: String) {
        let url = URL(string: "http://your-api.com/auth/apple-login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["authorization_code": authorizationCode]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            // 处理响应
        }.resume()
    }
}
```

### Android Kotlin 示例

```kotlin
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions

class AppleSignInManager(private val activity: Activity) {
    fun appleLogin() {
        // 注意：Android 需要使用第三方库或 Web 视图实现 Apple 登录
        // 推荐使用 https://github.com/TomGeshury/sign-in-with-apple-android

        // 示例代码会因库而异
    }
}
```

## 🔒 安全注意事项

1. **客户端密钥保护**
   - 永远不要在前端暴露 Apple 的私钥
   - 所有敏感操作都在服务端进行

2. **授权码验证**
   - authorization code 只能使用一次
   - 服务端验证成功后立即使用

3. **用户数据安全**
   - 不要存储 Apple 的 access_token 和 refresh_token（除非需要刷新令牌）
   - 只存储必要的用户信息（email, apple_id）

4. **错误处理**
   - 妥善处理无效或过期的 authorization code
   - 检查 Apple ID 和邮箱的重复性

## 🐛 故障排除

### 常见错误

1. **Invalid Apple authorization code**
   - 检查 authorization_code 是否有效
   - 确保 code 没有过期
   - 检查 client_id 是否正确

2. **Apple OAuth is not configured**
   - 检查所有 Apple 配置是否在 .env 中设置
   - 重新启动服务以加载新配置

3. **Database connection error**
   - 确保 PostgreSQL 服务正在运行
   - 检查 DATABASE_URL 是否正确

## 📚 参考资料

- [Apple Sign In 官方文档](https://developer.apple.com/documentation/authenticationservices/implementing_user_authentication_with_sign_in_with_apple)
- [FastAPI 官方文档](https://fastapi.tiangolo.com/)
- [SQLAlchemy 文档](https://docs.sqlalchemy.org/)

## 🎉 完成！

你现在已经成功集成了 Apple Sign In 功能。移动应用用户现在可以使用他们的 Apple ID 快速、安全地登录你的服务。
