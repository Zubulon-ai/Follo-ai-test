from datetime import datetime, timedelta

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.src.events.models import Event
from api.src.events.schemas import EventCreate


class EventRepository:
    """Repository for event database operations."""

    def __init__(self, session: AsyncSession):
        self.session = session

    async def create(self, user_id: int, event_data: EventCreate) -> Event:
        """Create a new event."""
        event = Event(
            user_id=user_id,
            source_event_id=event_data.source_event_id,
            title=event_data.title,
            start_at=datetime.fromisoformat(event_data.start_at.replace("Z", "+00:00")),
            end_at=datetime.fromisoformat(event_data.end_at.replace("Z", "+00:00")),
            state=event_data.state,
            event_type=event_data.event_type,
            location=event_data.location,
            notes=event_data.notes,
            is_all_day=event_data.is_all_day,
            timezone=event_data.timezone,
        )
        self.session.add(event)
        await self.session.flush()
        return event

    async def get_by_id(self, event_id: str) -> Event | None:
        """Get event by ID."""
        result = await self.session.execute(
            select(Event).where(Event.id == event_id)
        )
        return result.scalar_one_or_none()

    async def get_by_source_id(self, user_id: int, source_event_id: str) -> Event | None:
        """Get event by source event ID for a specific user."""
        result = await self.session.execute(
            select(Event).where(
                Event.user_id == user_id,
                Event.source_event_id == source_event_id
            )
        )
        return result.scalar_one_or_none()

    async def get_user_events(self, user_id: int) -> list[Event]:
        """Get all events for a user."""
        result = await self.session.execute(
            select(Event).where(Event.user_id == user_id).order_by(Event.start_at)
        )
        return list(result.scalars().all())

    async def get_upcoming_events(self, user_id: int, days: int = 5) -> list[Event]:
        """Get upcoming events for a user within the specified days."""
        now = datetime.utcnow()
        future = now + timedelta(days=days)
        result = await self.session.execute(
            select(Event).where(
                Event.user_id == user_id,
                Event.start_at >= now,
                Event.start_at <= future
            ).order_by(Event.start_at)
        )
        return list(result.scalars().all())

    async def delete_user_events(self, user_id: int) -> int:
        """Delete all events for a user. Returns count of deleted events."""
        result = await self.session.execute(
            delete(Event).where(Event.user_id == user_id)
        )
        return result.rowcount

    async def delete_past_events(self, user_id: int) -> int:
        """Delete past events for a user. Returns count of deleted events."""
        now = datetime.utcnow()
        result = await self.session.execute(
            delete(Event).where(
                Event.user_id == user_id,
                Event.end_at < now
            )
        )
        return result.rowcount

    async def update_event_state(self, event_id: str, state: str) -> Event | None:
        """Update event state."""
        event = await self.get_by_id(event_id)
        if event:
            event.state = state
            await self.session.flush()
        return event
