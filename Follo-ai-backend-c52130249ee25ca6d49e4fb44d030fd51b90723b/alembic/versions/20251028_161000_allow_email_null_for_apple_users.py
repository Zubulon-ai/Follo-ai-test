"""allow email null for apple users

Revision ID: allow_email_null
Revises: add_apple_signin
Create Date: 2025-10-28 16:10:00.000000

"""

from collections.abc import Sequence

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "allow_email_null"
down_revision: str | None = "add_apple_signin"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Allow email to be NULL for Apple Sign In users."""
    # 修改 email 列，允许为 NULL
    op.alter_column(
        "users",
        "email",
        nullable=True,
    )


def downgrade() -> None:
    """Restore email column to non-NULL."""
    # 恢复 email 为非 NULL（需要确保所有现有用户都有邮箱）
    op.alter_column(
        "users",
        "email",
        nullable=False,
    )
