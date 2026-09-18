"""ReliefSync API.

Run:  uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
Docs: http://localhost:8000/docs
"""
import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy import text

from .api import admin, auth, me, reports, volunteer
from .api.deps import engine_lock
from .app_config import seed_config
from .config import get_settings
from .db import Base, SessionLocal, engine
from .services import agencies, confirmation, dispatch, simulation

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("reliefsync")


def init_db() -> None:
    Base.metadata.create_all(engine)
    if engine.dialect.name == "postgresql":
        # Supabase: the API is the only DB client; RLS without policies closes the
        # tables to the public anon/authenticated REST keys (NFR-14/15).
        with engine.begin() as conn:
            for table in Base.metadata.sorted_tables:
                conn.execute(text(f'ALTER TABLE "{table.name}" ENABLE ROW LEVEL SECURITY'))
        # Open one connection now, at startup, instead of paying the first-query
        # cost on whichever user request happens to hit it first. Raw TCP to
        # Supabase's pooler is fast (checked directly) -- the actual delay is
        # Supabase's free-tier Postgres compute waking from auto-pause after
        # being idle, which is a one-time cost regardless of how many
        # connections are opened, so we only need to trigger it once.
        with engine.connect() as c:
            c.execute(text("SELECT 1"))
    with SessionLocal() as db:
        seed_config(db)
        agencies.seed_agencies(db)
        if get_settings().seed_demo_data:
            simulation.seed_demo(db)


def run_tick() -> None:
    """One engine step: batch escalation, simulated volunteers, confirmation/AFK/24h."""
    with engine_lock, SessionLocal() as db:
        try:
            dispatch.tick(db)
            simulation.tick(db)
            confirmation.tick(db)
            db.commit()
        except Exception:
            db.rollback()
            log.exception("engine tick failed")


async def _engine_loop(interval: float) -> None:
    while True:
        await asyncio.to_thread(run_tick)
        await asyncio.sleep(interval)


@asynccontextmanager
async def lifespan(_: FastAPI):
    settings = get_settings()
    init_db()
    task = asyncio.create_task(_engine_loop(settings.tick_seconds)) if settings.run_engine else None
    log.info("ReliefSync API ready (db=%s, ai=%s)", settings.database_url.split("@")[-1],
             "claude" if settings.anthropic_api_key else "rule-based")
    yield
    if task:
        task.cancel()


app = FastAPI(title="ReliefSync API", version="1.0.0", lifespan=lifespan,
              description="Disaster-response matching for IFest 2026 (Tim STEICON).")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

for r in (auth.router, me.router, reports.router, volunteer.router, admin.router):
    app.include_router(r)

_uploads = get_settings().upload_dir
_uploads.mkdir(parents=True, exist_ok=True)
app.mount("/uploads", StaticFiles(directory=_uploads), name="uploads")


@app.get("/health")
def health():
    s = get_settings()
    return {"ok": True, "ai": "claude" if s.anthropic_api_key else "rule-based",
            "fcm": bool(s.firebase_credentials)}
