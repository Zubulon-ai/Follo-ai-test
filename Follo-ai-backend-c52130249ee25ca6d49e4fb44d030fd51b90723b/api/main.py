from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from api.core.config import settings
from api.core.logging import get_logger, setup_logging
from api.src.heroes.routes import router as heroes_router
from api.src.users.routes import router as auth_router
from api.src.dashscope.routes import router as dashscope_router
from api.src.events.routes import router as events_router
from api.src.context.routes import router as context_router

# Set up logging configuration
setup_logging()

# Optional: Run migrations on startup
# run_migrations()

# Set up logger for this module
logger = get_logger(__name__)

app = FastAPI(
    title=settings.PROJECT_NAME,
    debug=settings.DEBUG,
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers with /api/v1 prefix
app.include_router(auth_router, prefix="/api/v1")
app.include_router(heroes_router, prefix="/api/v1")
app.include_router(dashscope_router, prefix="/api/v1")
app.include_router(events_router, prefix="/api/v1")
app.include_router(context_router, prefix="/api/v1")


@app.get("/health")
async def health_check():
    return {"status": "ok"}


@app.get("/")
async def root():
    """Root endpoint."""
    logger.debug("Root endpoint called")
    return {"message": "Welcome to Hero API!"}
