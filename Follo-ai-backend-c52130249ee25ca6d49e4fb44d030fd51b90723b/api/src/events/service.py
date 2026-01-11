from sqlalchemy.ext.asyncio import AsyncSession

from api.core.logging import get_logger
from api.src.events.models import Event
from api.src.events.repository import EventRepository
from api.src.events.schemas import EventCreate, EventResponse

logger = get_logger(__name__)


class EventService:
    """Service for event business logic."""

    def __init__(self, session: AsyncSession):
        self.session = session
        self.repository = EventRepository(session)

    async def sync_events(self, user_id: int, events: list[EventCreate]) -> int:
        """
        Sync events for a user using delete-then-add strategy.
        Returns the count of synced events.
        """
        # Delete existing events for the user
        deleted_count = await self.repository.delete_user_events(user_id)
        logger.info(f"Deleted {deleted_count} existing events for user {user_id}")

        # Create new events
        for event_data in events:
            await self.repository.create(user_id, event_data)

        await self.session.commit()
        logger.info(f"Synced {len(events)} events for user {user_id}")
        return len(events)

    async def get_upcoming_events(self, user_id: int, days: int = 5) -> list[EventResponse]:
        """Get upcoming events for a user."""
        events = await self.repository.get_upcoming_events(user_id, days)
        return [self._to_response(event) for event in events]

    async def auto_sync(self, user_id: int) -> bool:
        """
        Perform auto sync: update event states and cleanup past events.
        """
        # Clean up past events
        deleted_count = await self.repository.delete_past_events(user_id)
        logger.info(f"Auto sync: cleaned up {deleted_count} past events for user {user_id}")

        await self.session.commit()
        return True

    def _to_response(self, event: Event) -> EventResponse:
        """Convert Event model to EventResponse."""
        return EventResponse(
            id=event.id,
            user_id=event.user_id,
            source_event_id=event.source_event_id,
            title=event.title,
            start_at=event.start_at.isoformat(),
            end_at=event.end_at.isoformat(),
            state=event.state,
            event_type=event.event_type,
            location=event.location,
            notes=event.notes,
            is_all_day=event.is_all_day,
            timezone=event.timezone,
            created_at=event.created_at.isoformat(),
            updated_at=event.updated_at.isoformat(),
        )
