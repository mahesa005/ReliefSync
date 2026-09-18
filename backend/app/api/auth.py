"""Registration, simulated OTP and login (FR-1.1 - FR-1.3)."""
import logging
from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import get_settings
from ..db import get_db
from ..models import User, VolunteerProfile, VolunteerSkill, utcnow
from ..security import create_token, generate_otp, hash_password, normalize_phone, verify_password
from .me import SkillIn, user_payload

router = APIRouter(prefix="/auth", tags=["auth"])
log = logging.getLogger("reliefsync.auth")


class RegisterIn(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    phone: str
    password: str = Field(min_length=6)
    become_volunteer: bool = False  # FR-1.3
    skills: list[SkillIn] = []


class VerifyIn(BaseModel):
    phone: str
    code: str


class PhoneIn(BaseModel):
    phone: str


class LoginIn(BaseModel):
    phone: str
    password: str


def _issue_otp(user: User) -> dict:
    user.otp_code = generate_otp()
    user.otp_expires_at = utcnow() + timedelta(minutes=10)
    log.info("OTP for %s: %s (simulated SMS)", user.phone, user.otp_code)
    out = {"phone": user.phone, "otp_sent": True}
    if get_settings().simulate_otp:
        out["dev_otp"] = user.otp_code  # MVP: OTP is simulated (FR-1.2)
    return out


def _valid_phone(raw: str) -> str:
    phone = normalize_phone(raw)
    if not (phone.startswith("08") and 10 <= len(phone) <= 14):
        raise HTTPException(422, "Nomor HP tidak valid. Contoh: 081234567890")
    return phone


@router.post("/register")
def register(body: RegisterIn, db: Session = Depends(get_db)):
    phone = _valid_phone(body.phone)
    user = db.scalar(select(User).where(User.phone == phone))
    if user is not None and user.phone_verified:
        raise HTTPException(409, "Nomor HP sudah terdaftar. Silakan masuk.")
    if user is None:
        user = User(phone=phone, name=body.name.strip(), password_hash=hash_password(body.password))
        db.add(user)
        db.flush()
    else:  # unverified leftover registration: overwrite
        user.name = body.name.strip()
        user.password_hash = hash_password(body.password)
    if body.become_volunteer and user.volunteer is None:
        db.add(VolunteerProfile(user_id=user.id, is_active=True))
        for s in {s.skill.strip(): s for s in body.skills if s.skill.strip()}.values():
            db.add(VolunteerSkill(user_id=user.id, skill=s.skill.strip(), evidence=s.evidence))
    out = _issue_otp(user)
    db.commit()
    return out


@router.post("/resend-otp")
def resend_otp(body: PhoneIn, db: Session = Depends(get_db)):
    user = db.scalar(select(User).where(User.phone == normalize_phone(body.phone)))
    if user is None:
        raise HTTPException(404, "Nomor HP belum terdaftar.")
    out = _issue_otp(user)
    db.commit()
    return out


@router.post("/verify-otp")
def verify_otp(body: VerifyIn, db: Session = Depends(get_db)):
    user = db.scalar(select(User).where(User.phone == normalize_phone(body.phone)))
    if user is None or not user.otp_code:
        raise HTTPException(400, "Kode OTP tidak valid.")
    if user.otp_expires_at and user.otp_expires_at < utcnow():
        raise HTTPException(400, "Kode OTP kedaluwarsa. Minta kode baru.")
    if body.code.strip() != user.otp_code:
        raise HTTPException(400, "Kode OTP salah.")
    user.phone_verified = True
    user.otp_code = None
    db.commit()
    return {"token": create_token(user.id), "user": user_payload(db, user)}


@router.post("/login")
def login(body: LoginIn, db: Session = Depends(get_db)):
    user = db.scalar(select(User).where(User.phone == normalize_phone(body.phone)))
    if user is None or user.is_simulated or not verify_password(body.password, user.password_hash):
        raise HTTPException(401, "Nomor HP atau kata sandi salah.")
    if not user.phone_verified:
        out = _issue_otp(user)
        db.commit()
        raise HTTPException(403, {"message": "Nomor HP belum diverifikasi.", **out})
    return {"token": create_token(user.id), "user": user_payload(db, user)}
