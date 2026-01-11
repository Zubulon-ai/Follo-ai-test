from fastapi import APIRouter, Depends

from api.core.logging import get_logger
from api.core.security import get_current_user
from api.src.users.models import User
from api.src.dashscope.schemas import (
    BackendAPIResponse,
    ChatAPIRequest,
    HARAPIRequest,
    MeetingAssistantAPIRequest,
    QuickCreateAPIRequest,
    RecommendationAPIRequest,
    TextResponse,
)
from api.src.dashscope.service import DashscopeService

logger = get_logger(__name__)

router = APIRouter(prefix="/dashscope", tags=["dashscope"])


@router.post("/greeting", response_model=BackendAPIResponse)
async def greeting(
    current_user: User = Depends(get_current_user),
) -> BackendAPIResponse:
    """Get a greeting message."""
    logger.debug(f"Greeting request from user: {current_user.id}")
    try:
        text = await DashscopeService.get_greeting(current_user)
        return BackendAPIResponse(
            success=True,
            data=TextResponse(text=text),
            message="Greeting generated successfully"
        )
    except Exception as e:
        logger.error(f"Greeting failed: {str(e)}")
        return BackendAPIResponse(
            success=False,
            data=None,
            message=str(e)
        )


@router.post("/har", response_model=BackendAPIResponse)
async def har_analysis(
    request: HARAPIRequest,
    current_user: User = Depends(get_current_user),
) -> BackendAPIResponse:
    """Perform HAR (Human Activity Recognition) analysis."""
    logger.debug(f"HAR analysis request from user: {current_user.id}")
    try:
        text = await DashscopeService.har_analysis(
            user_info=request.user_info,
            calendar_json=request.calendar_json,
            sensor_json=request.sensor_json,
            current_time_info=request.current_time_info,
        )
        return BackendAPIResponse(
            success=True,
            data=TextResponse(text=text),
            message="HAR analysis completed"
        )
    except Exception as e:
        logger.error(f"HAR analysis failed: {str(e)}")
        return BackendAPIResponse(
            success=False,
            data=None,
            message=str(e)
        )


@router.post("/recommendations", response_model=BackendAPIResponse)
async def get_recommendations(
    request: RecommendationAPIRequest,
    current_user: User = Depends(get_current_user),
) -> BackendAPIResponse:
    """Get personalized recommendations."""
    logger.debug(f"Recommendations request from user: {current_user.id}")
    try:
        text = await DashscopeService.get_recommendations(
            user_info=request.user_info,
            calendar_json=request.calendar_json,
            sensor_json=request.sensor_json,
            time=request.time,
        )
        return BackendAPIResponse(
            success=True,
            data=TextResponse(text=text),
            message="Recommendations generated"
        )
    except Exception as e:
        logger.error(f"Recommendations failed: {str(e)}")
        return BackendAPIResponse(
            success=False,
            data=None,
            message=str(e)
        )


@router.post("/meeting-assistant", response_model=BackendAPIResponse)
async def meeting_assistant(
    request: MeetingAssistantAPIRequest,
    current_user: User = Depends(get_current_user),
) -> BackendAPIResponse:
    """Get meeting scheduling assistance."""
    logger.debug(f"Meeting assistant request from user: {current_user.id}")
    try:
        text = await DashscopeService.meeting_assistant(
            prompt_text=request.prompt_text,
            recipient_name=request.recipient_name,
            recipient_prefs_json=request.recipient_prefs_json,
            recipient_calendar_json=request.recipient_calendar_json,
            requester_name=request.requester_name,
            requester_user_info=request.requester_user_info,
            requester_calendar_events=request.requester_calendar_events,
        )
        return BackendAPIResponse(
            success=True,
            data=TextResponse(text=text),
            message="Meeting assistant response generated"
        )
    except Exception as e:
        logger.error(f"Meeting assistant failed: {str(e)}")
        return BackendAPIResponse(
            success=False,
            data=None,
            message=str(e)
        )


@router.post("/quick-create", response_model=BackendAPIResponse)
async def quick_create(
    request: QuickCreateAPIRequest,
    current_user: User = Depends(get_current_user),
) -> BackendAPIResponse:
    """Quick create event or task."""
    logger.debug(f"Quick create request from user: {current_user.id}")
    try:
        text = await DashscopeService.quick_create(
            prompt=request.prompt,
            user_info=request.user_info,
            calendar_events=request.calendar_events,
            recent_status_data=request.recent_status_data,
        )
        return BackendAPIResponse(
            success=True,
            data=TextResponse(text=text),
            message="Quick create response generated"
        )
    except Exception as e:
        logger.error(f"Quick create failed: {str(e)}")
        return BackendAPIResponse(
            success=False,
            data=None,
            message=str(e)
        )


@router.post("/chat", response_model=BackendAPIResponse)
async def chat(
    request: ChatAPIRequest,
    current_user: User = Depends(get_current_user),
) -> BackendAPIResponse:
    """General chat endpoint."""
    logger.debug(f"Chat request from user: {current_user.id}")
    try:
        text = await DashscopeService.chat(
            prompt=request.prompt,
            user_info=request.user_info,
            calendar_events=request.calendar_events,
            recent_status_data=request.recent_status_data,
        )
        return BackendAPIResponse(
            success=True,
            data=TextResponse(text=text),
            message="Chat response generated"
        )
    except Exception as e:
        logger.error(f"Chat failed: {str(e)}")
        return BackendAPIResponse(
            success=False,
            data=None,
            message=str(e)
        )
