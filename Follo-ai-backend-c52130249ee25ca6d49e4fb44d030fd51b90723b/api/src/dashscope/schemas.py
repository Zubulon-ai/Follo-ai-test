from typing import Any
from pydantic import BaseModel


class TextResponse(BaseModel):
    """Text response model."""
    text: str


class BackendAPIResponse(BaseModel):
    """Generic API response model."""
    success: bool
    data: TextResponse | None = None
    message: str


class HARAPIRequest(BaseModel):
    """HAR analysis request model."""
    user_info: dict[str, str]
    calendar_json: str
    sensor_json: str
    current_time_info: str


class RecommendationAPIRequest(BaseModel):
    """Recommendation request model."""
    user_info: dict[str, str]
    calendar_json: str
    sensor_json: str
    time: str


class MeetingAssistantAPIRequest(BaseModel):
    """Meeting assistant request model."""
    prompt_text: str
    recipient_name: str
    recipient_prefs_json: str
    recipient_calendar_json: str
    requester_name: str
    requester_user_info: dict[str, str] | None = None
    requester_calendar_events: list[dict[str, Any]] | None = None


class QuickCreateAPIRequest(BaseModel):
    """Quick create request model."""
    prompt: str
    user_info: dict[str, str] | None = None
    calendar_events: list[dict[str, Any]] | None = None
    recent_status_data: list[str]


class ChatAPIRequest(BaseModel):
    """Chat request model."""
    prompt: str
    user_info: dict[str, str] | None = None
    calendar_events: list[dict[str, Any]] | None = None
    recent_status_data: list[str]
