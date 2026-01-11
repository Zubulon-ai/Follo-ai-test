# 🚀 FastAPI & PostgreSQL 生产级项目模板

本项目基于https://github.com/luchog01/minimalistic-fastapi-template模版开发

## ✨ 核心功能

  * **现代工具栈**: FastAPI, `uv` (极速包管理), PostgreSQL
  * **全异步**: 使用 `asyncpg` 和 `AsyncSession` 实现高性能
  * **数据库迁移**: 集成 **Alembic**，用于管理数据库结构变更
  * **清晰的架构**: 采用**服务层 (Service)** 和**仓库层 (Repository)** 的分层设计
  * **内置认证**: 预先配置了 **JWT Token** 认证，包含注册、登录接口
  * **代码规范**: 预设 `pre-commit`，自动格式化和检查代码

-----

## 🛠️ 本地开发环境启动指南

这是在你的电脑上运行此项目的**推荐步骤**。

### 1\. 克隆你的项目

```bash
# 替换成你自己的私有仓库地址
git clone https://github.com/kings099/Follo-ai-backend.git
cd Follo-ai-backend
```

### 2\. 安装 `uv`

如果你还没有 `uv`，请先在你的电脑上安装它。

```bash
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh
# Windows
powershell -c "irm https://astral.sh/uv/install.ps1 | iex"
```

### 3\. 创建虚拟环境并安装依赖

`uv` 会自动在当前目录创建 `.venv` 虚拟环境并安装所有包。

```bash
uv sync
```

*(**注意**: 如果你遇到 `No module named 'greenlet'` 相关的错误, 请手动运行 `uv pip install greenlet`)*

### 4\. 配置环境变量

复制示例文件，然后**编辑你自己的 `.env` 文件**。

```bash
cp .env.example .env
```

打开 `.env` 文件，修改 `DATABASE_URL` 以匹配你**本地**的 PostgreSQL 数据库。

> **💡 重要提示**:
> `DATABASE_URL` 必须使用 `postgresql+asyncpg://` 驱动。
>
> **示例:**
> `DATABASE_URL=postgresql+asyncpg://你的用户名:你的密码@localhost:5432/你的数据库名`

### 5\. 创建你的本地数据库

在你的本地 PostgreSQL 服务中（例如使用 DataGrip 或 `psql`），创建一个**空的**数据库。

```sql
-- 确保这个名字和你在 .env 中填写的 "你的数据库名" 一致
CREATE DATABASE myapp_db;
```

### 6\. 运行数据库迁移 (Alembic)

这一步会连接到你的本地数据库，并自动创建 `users`, `heroes` 等所有表。

```bash
uv run alembic upgrade head
```

### 7\. 禁用自动迁移

为了避免启动时出错（就像我们之前遇到的 `greenlet` 错误），我**注释掉**了启动时的自动迁移检查。

<!-- end list -->

```python
...
from api.utils.migrations import run_migrations

# run_migrations()  <-- 不进行自动更新

app = FastAPI(...)
...
```

*这样做更安全。之后当你需要更新数据库时，请**手动**运行 `uv run alembic upgrade head`。*

### 8\. 启动！

```bash
uv run uvicorn api.main:app --reload
```

服务器现在运行在 `http://127.0.0.1:8000`。

-----

## 🧪 如何测试你的 API

启动服务后，打开浏览器并访问 **`http://127.0.0.1:8000/docs`**。

你将看到 FastAPI 自动生成的交互式 API 文档。你可以按照以下流程测试：

1.  使用 `POST /auth/register` 注册一个新用户。
2.  点击页面右上角的 `Authorize` 按钮，输入账号（邮箱）密码登录。
3.  现在你可以测试被保护的 `heroes` 接口了！

-----

## 👨‍💻 如何继续开发 (添加新功能)

这正是这个模板的核心价值。假设你要为你 App 添加一个“商品 (Products)”功能：

**你的主要工作目录是 `api/src/`**。

1.  **创建新模块**:
    在 `api/src/` 下创建一个新文件夹 `products`。

2.  **复制架构**:
    参考 `api/src/heroes/` 和 `api/src/users/` 的结构，在 `products` 文件夹下创建以下文件：

      * `models.py`: 定义 `Product` SQLAlchemy 模型 (数据库表结构)。
      * `schemas.py`: 定义 `ProductCreate`, `ProductUpdate`, `ProductResponse` Pydantic 模型 (API 数据形状)。
      * `repository.py`: 创建 `ProductRepository` 类。**只在这里写数据库操作** (增删改查)。
      * `service.py`: 创建 `ProductService` 类。**只在这里写业务逻辑** (例如：检查库存、计算价格等)。
      * `routes.py`: 创建 `router`。**只在这里定义 API 路由** (例如 `@router.post("/")`)。

3.  **更新数据库 (Alembic)**:

      * 请看下一节的“数据库迁移”指南。

4.  **注册新路由**:

      * 打开 `api/main.py`，导入并 `include` 你的新 `products` 路由，就像 `heroes_router` 和 `users_router` 一样。

-----

## 🔄 数据库迁移 (Alembic)

当你修改了任何 `models.py` 文件（例如，给 `User` 表加了一个新字段，或创建了 `Product` 表），你需要按以下流程更新数据库结构：

### 1\. (重要) 让 Alembic "看到" 你的模型

打开 `alembic/env.py` 文件。
在顶部，导入你新创建的 `Product` 模型：

```python
...
from api.src.heroes.models import Hero  # 示例
from api.src.users.models import User  # 示例
from api.src.products.models import Product  # <-- 在这里添加你的新模型
...
```

*这会确保 Alembic 在自动生成迁移时能检测到你的新表。*

### 2\. 自动生成迁移脚本

在终端运行：

```bash
# "add_products_table" 只是一个描述，你可以自己起名
uv run alembic revision --autogenerate -m "add_products_table"
```

Alembic 会比较你的模型和数据库，并在 `alembic/versions/` 文件夹下创建一个新的 `.py` 脚本。

### 3\. 应用迁移

运行此命令来执行该脚本，并真实地更新你的本地数据库：

```bash
uv run alembic upgrade head
```

### 4\. 提交代码

**把你的代码** (`models.py`, `routes.py`...) 和**新生成的迁移脚本** (`alembic/versions/....py`) 一起 `git commit`。当你的队友 `git pull` 并运行 `uv run alembic upgrade head` 时，他们的数据库也会被同步更新。

-----

## 📁 项目结构

```
api/
├── core/              # 核心功能 (配置, 数据库连接, 认证)
│   ├── config.py      # 读取 .env
│   ├── database.py    # 数据库会话 (get_session)
│   ├── exceptions.py  # 全局异常处理
│   ├── logging.py     # 日志配置
│   └── security.py    # JWT 和密码哈希
├── src/               # 业务逻辑 (你的主要工作区)
│   ├── heroes/        # 【示例模块】
│   │   ├── models.py      # SQLAlchemy 模型 (表)
│   │   ├── repository.py  # 数据库操作 (CRUD)
│   │   ├── routes.py      # API 路由 (@app.get, @app.post)
│   │   ├── schemas.py     # Pydantic 模型 (请求/响应)
│   │   └── service.py     # 业务逻辑
│   └── users/         # 【认证模块】
│       ├── ...
├── utils/             # 辅助工具 (例如自动迁移脚本)
└── main.py            # FastAPI 应用入口 (加载路由)
alembic/               # 数据库迁移脚本
tests/                 # 自动化测试
.env.example           # 环境变量模板
pyproject.toml         # 项目依赖 (uv)
```