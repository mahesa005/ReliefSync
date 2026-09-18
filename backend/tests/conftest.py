import os
import tempfile
from pathlib import Path

_tmp = Path(tempfile.mkdtemp(prefix="reliefsync-test-"))
os.environ.update({
    "DATABASE_URL": f"sqlite:///{_tmp / 'test.db'}",
    "RUN_ENGINE": "false",
    "SEED_DEMO_DATA": "false",
    "ANTHROPIC_API_KEY": "",
    "SIMULATE_OTP": "true",
    "FIREBASE_CREDENTIALS": "",
    "UPLOAD_DIR": str(_tmp / "uploads"),
})

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.app_config import seed_config  # noqa: E402
from app.db import Base, SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.services.agencies import seed_agencies  # noqa: E402


@pytest.fixture
def db():
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    session = SessionLocal()
    seed_config(session)
    seed_agencies(session)
    yield session
    session.close()


@pytest.fixture
def client(db):
    with TestClient(app) as c:
        yield c
