from fastapi import APIRouter, Depends

from api.core.logging import get_logger
from api.core.security import get_current_user
from api.src.context.schemas import ContextEngineRequest, ContextEngineResponse
from api.src.context.service import ContextService
from api.src.users.models import User

logger = get_logger(__name__)

router = APIRouter(prefix="/context", tags=["context"])


@router.post("/engine", response_model=ContextEngineResponse)
async def context_engine(
    request: ContextEngineRequest,
    current_user: User = Depends(get_current_user),
) -> ContextEngineResponse:
    """
    Process context snapshot and return decision with optional notification.
    """
    logger.debug(f"Context engine request from user {current_user.id}, trigger: {request.trigger}")
    try:
        response = await ContextService.process_context(
            user=current_user,
            trigger=request.trigger,
            snapshot=request.snapshot
        )
        logger.info(f"Context engine decision: {response.decision}")
        return response
    except Exception as e:
        logger.error(f"Context engine failed: {str(e)}")
        return ContextEngineResponse(
            decision="error",
            reasoning=str(e),
            notification=None
        )
