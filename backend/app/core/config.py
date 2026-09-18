"""Environment settings (infrastructure only).

Business tunables (weights, radius, timeouts, quotas, ...) live in the
``app_config`` table instead -- see ``app/core/app_config.py``.
"""
from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

BASE_DIR = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=BASE_DIR / ".env", extra="ignore")

    database_url: str = f"sqlite:///{BASE_DIR / 'reliefsync.db'}"

    jwt_secret: str = "reliefsync-dev-secret-change-me-in-production"
    jwt_expire_days: int = 30
    simulate_otp: bool = True

    groq_api_key: str = ""
    llm_model: str = "llama-3.3-70b-versatile"
    llm_timeout_seconds: float = 5.0

    supabase_url: str = ""
    supabase_service_role_key: str = ""
    supabase_bucket: str = "report-photos"
    upload_dir: Path = BASE_DIR / "uploads"

    firebase_credentials: str = ""

    tick_seconds: float = 2.0
    seed_demo_data: bool = True
    run_engine: bool = True  # tests switch this off and drive the engine manually


@lru_cache
def get_settings() -> Settings:
    return Settings()
