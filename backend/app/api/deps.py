import threading
from datetime import datetime

from fastapi import Depends, Header, HTTPException
from sqlalchemy.orm import Session

from ..core.security import decode_token
from ..db.models import User
from ..db.session import get_db

# Serialises state-changing engine operations (accept, vote, tick, ...) so the
# background ticker and request handlers never race on the same need.
engine_lock = threading.RLock()


def current_user(authorization: str | None = Header(default=None), db: Session = Depends(get_db)) -> User:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Silakan masuk terlebih dahulu.")
    user_id = decode_token(authorization.split(" ", 1)[1])
    user = db.get(User, user_id) if user_id else None
    if user is None or not user.phone_verified:
        raise HTTPException(401, "Sesi tidak valid. Silakan masuk kembali.")
    return user


def iso(dt: datetime | None) -> str | None:
    return dt.isoformat(timespec="seconds") + "Z" if dt else None
