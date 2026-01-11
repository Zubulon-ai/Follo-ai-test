"""add apple signin fields

Revision ID: add_apple_signin
Revises: ef2910566747
Create Date: 2025-10-27 21:03:08.000000

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "add_apple_signin"
down_revision: str | None = "ef2910566747"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Add Apple Sign In fields to users table."""
    # 添加 apple_id 列
    op.add_column(
        "users",
        sa.Column("apple_id", sa.String(), nullable=True, unique=True, index=True),
    )

    # 添加 is_active 列
    op.add_column(
        "users",
        sa.Column("is_active", sa.Boolean(), nullable=True, default=True),
    )

    # 修改 hashed_password 列，允许为 NULL（用于 Apple 登录用户）
    op.alter_column(
        "users",
        "hashed_password",
        nullable=True,
    )


def downgrade() -> None:
    """Remove Apple Sign In fields from users table."""
    # 删除 is_active 列
    op.drop_column("users", "is_active")

    # 删除 apple_id 列
    op.drop_column("users", "apple_id")

    # 恢复 hashed_password 为非 NULL
    op.alter_column(
        "users",
        "hashed_password",
        nullable=False,
    )
