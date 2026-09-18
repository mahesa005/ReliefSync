import hashlib
import hmac
import re
import secrets
from datetime import timedelta

import jwt

from ..db.models import utcnow
from .config import get_settings

_PBKDF2_ROUNDS = 200_000


def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), _PBKDF2_ROUNDS)
    return f"pbkdf2${salt}${digest.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        _, salt, hex_digest = stored.split("$")
    except ValueError:
        return False
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), _PBKDF2_ROUNDS)
    return hmac.compare_digest(digest.hex(), hex_digest)


def create_token(user_id: str) -> str:
    s = get_settings()
    payload = {"sub": user_id, "exp": utcnow() + timedelta(days=s.jwt_expire_days)}
    return jwt.encode(payload, s.jwt_secret, algorithm="HS256")


def decode_token(token: str) -> str | None:
    try:
        return jwt.decode(token, get_settings().jwt_secret, algorithms=["HS256"])["sub"]
    except jwt.PyJWTError:
        return None


def normalize_phone(raw: str) -> str:
    """'+62 812-3456-7890' / '6281234567890' / '081234567890' -> '081234567890'."""
    digits = re.sub(r"\D", "", raw or "")
    if digits.startswith("62"):
        digits = "0" + digits[2:]
    elif digits.startswith("8"):
        digits = "0" + digits
    return digits


def mask_phone(phone: str | None) -> str | None:
    """FR-9.4 / NFR-14: '081234567890' -> '0812****7890'."""
    if not phone:
        return None
    if len(phone) <= 6:
        return "*" * len(phone)
    return phone[:4] + "*" * (len(phone) - 8 if len(phone) > 8 else 2) + phone[-4:]


def generate_otp() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"
