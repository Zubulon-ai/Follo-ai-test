from typing import Any
from pydantic import BaseModel


class LocationData(BaseModel):
    """Location data model."""
    latitude: float | None = None
    longitude: float | None = None
    altitude: float | None = None
    accuracy: float | None = None
    timestamp: str | None = None


class MotionData(BaseModel):
    """Motion data model."""
    activity_type: str | None = None
    confidence: float | None = None
    steps: int | None = None
    timestamp: str | None = None


class HealthData(BaseModel):
    """Health data model."""
    heart_rate: float | None = None
    step_count: int | None = None
    active_energy: float | None = None
    timestamp: str | None = None


class CalendarEvent(BaseModel):
    """Calendar event in context snapshot."""
    title: str
    start: str
    end: str
    location: str | None = None
    is_all_day: bool = False


class ContextSnapshot(BaseModel):
    """Context snapshot model."""
    timestamp: str
    location: LocationData | None = None
    motion: MotionData | None = None
    health: HealthData | None = None
    calendar_events: list[CalendarEvent] | None = None
    user_info: dict[str, Any] | None = None
    recent_status: list[str] | None = None


class NotificationPayload(BaseModel):
    """Notification payload model."""
    priority: str | None = None
    title: str
    body: str
    action_label: str | None = None


class ContextEngineRequest(BaseModel):
    """Context engine request model."""
    trigger: str
    snapshot: ContextSnapshot


class ContextEngineResponse(BaseModel):
    """Context engine response model."""
    decision: str
    reasoning: str | None = None
    notification: NotificationPayload | None = None
