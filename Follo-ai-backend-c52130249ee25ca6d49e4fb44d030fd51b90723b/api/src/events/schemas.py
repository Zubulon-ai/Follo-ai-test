from datetime import datetime
from pydantic import BaseModel, ConfigDict


class EventCreate(BaseModel):
    """Event creation model."""
    source_event_id: str
    title: str
    start_at: str
    end_at: str
    state: str
    event_type: str | None = None
    location: str | None = None
    notes: str | None = None
    is_all_day: bool | None = None
    timezone: str | None = None


class EventSyncRequest(BaseModel):
    """Event sync request model."""
    events: list[EventCreate]


class EventSyncResponse(BaseModel):
    """Event sync response model."""
    success: bool
    message: str
    synced_count: int


class EventResponse(BaseModel):
    """Event response model."""
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: int
    source_event_id: str
    title: str
    start_at: str
    end_at: str
    state: str
    event_type: str | None = None
    location: str | None = None
    notes: str | None = None
    is_all_day: bool | None = None
    timezone: str | None = None
    created_at: str
    updated_at: str


class EventUpcomingResponse(BaseModel):
    """Upcoming events response model."""
    success: bool
    count: int
    events: list[EventResponse]
    message: str | None = None


class AutoSyncResponse(BaseModel):
    """Auto sync response model."""
    success: bool
    message: str
