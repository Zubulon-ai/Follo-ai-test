from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.database import get_session
from api.core.logging import get_logger
from api.core.security import get_current_user
from api.src.events.schemas import (
    AutoSyncResponse,
    EventSyncRequest,
    EventSyncResponse,
    EventUpcomingResponse,
)
from api.src.events.service import EventService
from api.src.users.models import User

logger = get_logger(__name__)

router = APIRouter(prefix="/events", tags=["events"])


@router.post("/sync", response_model=EventSyncResponse)
async def sync_events(
    request: EventSyncRequest,
    current_user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
) -> EventSyncResponse:
    """Sync events from client to server."""
    logger.debug(f"Sync request from user {current_user.id} with {len(request.events)} events")
    try:
        service = EventService(session)
        synced_count = await service.sync_events(current_user.id, request.events)
        return EventSyncResponse(
            success=True,
            message=f"Successfully synced {synced_count} events",
            synced_count=synced_count
        )
    except Exception as e:
        logger.error(f"Event sync failed: {str(e)}")
        return EventSyncResponse(
            success=False,
            message=str(e),
            synced_count=0
        )


@router.get("/upcoming", response_model=EventUpcomingResponse)
async def get_upcoming_events(
    days: int = 5,
    current_user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
) -> EventUpcomingResponse:
    """Get upcoming events for the authenticated user."""
    logger.debug(f"Upcoming events request from user {current_user.id} for {days} days")
    try:
        service = EventService(session)
        events = await service.get_upcoming_events(current_user.id, days)
        return EventUpcomingResponse(
            success=True,
            count=len(events),
            events=events,
            message=f"Found {len(events)} upcoming events"
        )
    except Exception as e:
        logger.error(f"Get upcoming events failed: {str(e)}")
        return EventUpcomingResponse(
            success=False,
            count=0,
            events=[],
            message=str(e)
        )


@router.post("/auto-sync", response_model=AutoSyncResponse)
async def trigger_auto_sync(
    current_user: User = Depends(get_current_user),
    session: AsyncSession = Depends(get_session),
) -> AutoSyncResponse:
    """Trigger auto sync: update event states and cleanup past events."""
    logger.debug(f"Auto sync triggered by user {current_user.id}")
    try:
        service = EventService(session)
        success = await service.auto_sync(current_user.id)
        return AutoSyncResponse(
            success=success,
            message="Auto sync completed successfully"
        )
    except Exception as e:
        logger.error(f"Auto sync failed: {str(e)}")
        return AutoSyncResponse(
            success=False,
            message=str(e)
        )
