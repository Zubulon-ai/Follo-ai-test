from api.core.logging import get_logger
from api.src.context.schemas import (
    ContextEngineResponse,
    ContextSnapshot,
    NotificationPayload,
)
from api.src.users.models import User

logger = get_logger(__name__)


class ContextService:
    """Service for context engine operations."""

    @staticmethod
    async def process_context(
        user: User,
        trigger: str,
        snapshot: ContextSnapshot
    ) -> ContextEngineResponse:
        """
        Process context snapshot and determine if notification is needed.
        """
        logger.info(f"Processing context for user {user.id}, trigger: {trigger}")

        # TODO: Integrate with actual AI service for context analysis
        # For now, return a mock response based on trigger type

        decision = "no_action"
        reasoning = None
        notification = None

        if trigger == "location_change":
            # Check if user arrived at a location with an event
            if snapshot.calendar_events:
                next_event = snapshot.calendar_events[0]
                decision = "notify"
                reasoning = f"User arrived at location, upcoming event: {next_event.title}"
                notification = NotificationPayload(
                    priority="normal",
                    title="即将开始的活动",
                    body=f"您的活动 '{next_event.title}' 即将开始",
                    action_label="查看详情"
                )

        elif trigger == "time_based":
            # Time-based reminder check
            if snapshot.calendar_events:
                next_event = snapshot.calendar_events[0]
                decision = "notify"
                reasoning = f"Time-based reminder for: {next_event.title}"
                notification = NotificationPayload(
                    priority="high",
                    title="活动提醒",
                    body=f"您的活动 '{next_event.title}' 将在15分钟后开始",
                    action_label="准备出发"
                )

        elif trigger == "activity_change":
            # Activity state change
            if snapshot.motion and snapshot.motion.activity_type:
                decision = "monitor"
                reasoning = f"Activity changed to: {snapshot.motion.activity_type}"

        elif trigger == "health_alert":
            # Health data alert
            if snapshot.health:
                decision = "notify"
                reasoning = "Health data requires attention"
                notification = NotificationPayload(
                    priority="high",
                    title="健康提醒",
                    body="建议您适当休息，注意身体状况",
                    action_label="了解更多"
                )

        else:
            decision = "no_action"
            reasoning = f"Unknown trigger type: {trigger}"

        return ContextEngineResponse(
            decision=decision,
            reasoning=reasoning,
            notification=notification
        )
