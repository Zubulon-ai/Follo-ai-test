"""Add events table

Revision ID: add_events_table
Revises: 20251028_161000_allow_email_null_for_apple_users
Create Date: 2026-01-11

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'add_events_table'
down_revision: Union[str, None] = '20251028_161000_allow_email_null_for_apple_users'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        'events',
        sa.Column('id', sa.String(36), primary_key=True),
        sa.Column('user_id', sa.Integer(), sa.ForeignKey('users.id', ondelete='CASCADE'), nullable=False, index=True),
        sa.Column('source_event_id', sa.String(255), nullable=False, index=True),
        sa.Column('title', sa.String(500), nullable=False),
        sa.Column('start_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('end_at', sa.DateTime(timezone=True), nullable=False),
        sa.Column('state', sa.String(50), nullable=False, server_default='pending'),
        sa.Column('event_type', sa.String(100), nullable=True),
        sa.Column('location', sa.String(500), nullable=True),
        sa.Column('notes', sa.Text(), nullable=True),
        sa.Column('is_all_day', sa.Boolean(), nullable=True, server_default='false'),
        sa.Column('timezone', sa.String(100), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.func.now(), onupdate=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('events')
