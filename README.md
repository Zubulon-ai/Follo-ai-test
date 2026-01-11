<p align="center">
  <img src="https://img.shields.io/badge/Platform-iOS%2017%2B-blue?logo=apple" alt="iOS 17+"/>
  <img src="https://img.shields.io/badge/Backend-FastAPI-009688?logo=fastapi" alt="FastAPI"/>
  <img src="https://img.shields.io/badge/AI-Qwen%2FDashScope-orange" alt="Qwen AI"/>
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License"/>
</p>

# 🌟 Follo AI - 智能情境感知日程助手

**Follo AI** 是一款基于人工智能的智能日程管理与情境感知助手应用。它能够根据用户的位置、活动状态、健康数据和日历事件，提供个性化的智能提醒和推荐，让您的生活更加有序高效。

---

## ✨ 核心功能

### 🧠 智能情境引擎 (Context Engine)
- **多维度感知**：整合位置、运动状态、健康数据、日历事件等多种上下文信息
- **智能决策**：基于 AI 分析用户当前情境，自动判断是否需要发送通知
- **触发机制**：支持位置变化、时间触发、活动状态变化、健康预警等多种触发条件

### 📅 日程管理
- **事件同步**：iOS 日历与云端实时同步
- **智能提醒**：基于位置和时间的智能活动提醒
- **快速创建**：通过自然语言快速创建日程事件

### 🤖 AI 助手功能
- **通用聊天**：智能对话助手，随时解答问题
- **HAR 分析**：人体活动识别与健康建议
- **个性化推荐**：基于用户画像和活动数据的商业推荐
- **会议助手**：智能会议安排与时间协调

### 🔐 安全认证
- **Apple Sign In**：支持 Apple 账号一键登录
- **JWT 双令牌**：Access Token + Refresh Token 机制，安全可靠
- **端到端加密**：敏感数据安全传输

---

## 🏗️ 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        Follo AI 系统架构                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐    │
│  │   iOS App    │────▶│   Backend    │────▶│   AI Engine  │    │
│  │  (SwiftUI)   │◀────│  (FastAPI)   │◀────│  (Dashscope) │    │
│  └──────────────┘     └──────────────┘     └──────────────┘    │
│         │                    │                                  │
│         ▼                    ▼                                  │
│  ┌──────────────┐     ┌──────────────┐                         │
│  │   EventKit   │     │  PostgreSQL  │                         │
│  │   HealthKit  │     │   Database   │                         │
│  │   CoreMotion │     └──────────────┘                         │
│  │   CoreLocation│                                              │
│  └──────────────┘                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📱 iOS 客户端

### 技术栈
- **SwiftUI** - 现代化声明式 UI 框架
- **EventKit** - 日历事件管理
- **HealthKit** - 健康数据读取
- **CoreMotion** - 运动状态检测
- **CoreLocation** - 位置服务

### 主要模块
| 模块 | 功能描述 |
|------|---------|
| `Auth` | Apple Sign In 认证、Token 管理 |
| `Calendar` | 日历视图、事件管理 |
| `AI` | AI 对话、智能助手 |
| `Voice` | 语音交互功能 |
| `Services` | 事件同步、提醒服务 |
| `Network` | API 请求封装 |

---

## 🖥️ 后端服务

### 技术栈
- **FastAPI** - 高性能异步 Web 框架
- **PostgreSQL** - 关系型数据库
- **SQLAlchemy** - ORM 框架 (异步)
- **Alembic** - 数据库迁移
- **JWT** - 身份认证
- **uv** - 极速包管理

### API 端点

#### 认证模块 `/api/v1/auth`
| 方法 | 端点 | 描述 |
|------|------|------|
| POST | `/register` | 用户注册 |
| POST | `/login` | 用户登录 |
| POST | `/apple-login` | Apple 登录 |
| POST | `/token/refresh` | 刷新令牌 |
| GET | `/me` | 获取当前用户信息 |

#### AI 服务模块 `/api/v1/dashscope`
| 方法 | 端点 | 描述 |
|------|------|------|
| POST | `/greeting` | 获取问候语 |
| POST | `/har` | HAR 活动分析 |
| POST | `/recommendations` | 个性化推荐 |
| POST | `/meeting-assistant` | 会议助手 |
| POST | `/quick-create` | 快速创建事件 |
| POST | `/chat` | 通用聊天 |

#### 事件模块 `/api/v1/events`
| 方法 | 端点 | 描述 |
|------|------|------|
| POST | `/sync` | 同步事件 |
| GET | `/upcoming` | 获取未来事件 |
| POST | `/auto-sync` | 自动同步触发 |

#### 情境引擎 `/api/v1/context`
| 方法 | 端点 | 描述 |
|------|------|------|
| POST | `/engine` | 处理情境快照 |

---

## 🚀 快速开始

### 后端部署

```bash
# 1. 克隆项目
git clone https://github.com/your-repo/Follo-ai-backend.git
cd Follo-ai-backend

# 2. 安装 uv (如果尚未安装)
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh
# Windows
powershell -c "irm https://astral.sh/uv/install.ps1 | iex"

# 3. 安装依赖
uv sync

# 4. 配置环境变量
cp .env.example .env
# 编辑 .env 文件，配置数据库连接和其他设置

# 5. 运行数据库迁移
uv run alembic upgrade head

# 6. 启动服务
uv run uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload
```

### iOS 客户端

1. 使用 Xcode 打开 `follo-ai-ios-main/Follo AI.xcodeproj`
2. 修改 `Info.plist` 中的 `BackendAPIURL` 为您的后端地址
3. 配置 Apple Sign In 相关证书和 Capabilities
4. 编译运行

---

## ⚙️ 环境配置

### 后端环境变量 (.env)

```env
# 数据库
DATABASE_URL=postgresql+asyncpg://user:password@localhost:5432/follo_ai

# JWT 设置
JWT_SECRET=your-super-secret-key-change-in-production
JWT_ALGORITHM=HS256
JWT_EXPIRATION=30

# Apple Sign In (可选)
APPLE_CLIENT_ID=com.your.app.id
APPLE_TEAM_ID=XXXXXXXXXX
APPLE_KEY_ID=XXXXXXXXXX
APPLE_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----

# 调试模式
DEBUG=false
```

### iOS 配置 (Info.plist)

```xml
<key>BackendAPIURL</key>
<string>http://your-backend-server:8000</string>
```

---

## 📊 数据模型

### 用户 (User)
```
id: Integer (主键)
email: String (可选, Apple 用户可能没有)
hashed_password: String (可选)
apple_id: String (可选, Apple 登录用户)
is_active: Boolean
```

### 事件 (Event)
```
id: UUID (主键)
user_id: Integer (外键)
source_event_id: String (iOS EventKit ID)
title: String
start_at: DateTime
end_at: DateTime
state: String (pending/completed/cancelled)
event_type: String
location: String
notes: Text
is_all_day: Boolean
timezone: String
created_at: DateTime
updated_at: DateTime
```

---

## 🔮 未来规划

- [ ] 🌐 多语言支持 (English, 日本語, 한국어)
- [ ] ⌚ Apple Watch 扩展
- [ ] 🏠 智能家居联动 (HomeKit)
- [ ] 📊 数据分析仪表盘
- [ ] 🤝 团队协作功能
- [ ] 🔔 更丰富的通知类型
- [ ] 🎨 主题定制

---

## 👥 团队

**未来实验室** - 致力于用 AI 改变生活方式

---

## 📄 开源协议

本项目采用 [MIT License](LICENSE) 开源协议。

---

<p align="center">
  <b>🌟 Star this project if you find it helpful! 🌟</b>
</p>
