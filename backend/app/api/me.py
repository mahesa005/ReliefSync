"""Own account: profile, volunteer layer, location, notifications (FR-1.4 - 1.7, 5.3, 5.8)."""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db import get_db
from ..models import (
    AccuracyFeedback,
    Assignment,
    Need,
    Notification,
    Participant,
    Report,
    User,
    VolunteerProfile,
    VolunteerSkill,
    utcnow,
)
from ..security import mask_phone
from ..services.trust import trust_payload
from .deps import current_user, iso

router = APIRouter(prefix="/me", tags=["me"])


class SkillIn(BaseModel):
    skill: str = Field(min_length=1, max_length=60)
    evidence: Literal["self_declared", "certified"] = "self_declared"


class VolunteerIn(BaseModel):
    skills: list[SkillIn]
    is_active: bool = True


class ActiveIn(BaseModel):
    is_active: bool


class ProfilePatch(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    notify_nearby: bool | None = None  # FR-1.7
    nearby_radius_km: float | None = Field(default=None, gt=0, le=20)


class LocationIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class TokenIn(BaseModel):
    token: str


class ReadIn(BaseModel):
    ids: list[int] = []
    all: bool = False


def volunteer_stats(db: Session, user: User) -> dict:
    """Profile statistics (5.3): per-skill counts, participations, completion rate."""
    rows = db.execute(
        select(Assignment, Need).join(Need, Need.id == Assignment.need_id)
        .where(Assignment.volunteer_id == user.id, Assignment.status != "dilepas")
    ).all()
    per_skill: dict[str, int] = {}
    finished = not_afk = 0
    for a, need in rows:
        per_skill[need.skill] = per_skill.get(need.skill, 0) + 1
        if a.status == "selesai":
            finished += 1
            p = db.scalar(select(Participant).where(Participant.report_id == a.report_id,
                                                    Participant.user_id == user.id))
            if p is not None and not p.afk:
                not_afk += 1
    return {
        "participations": len({a.report_id for a, _ in rows}),
        "finished": finished,
        "completion_rate": round(not_afk / finished, 2) if finished else None,
        "per_skill": per_skill,
    }


def user_payload(db: Session, user: User) -> dict:
    v = user.volunteer
    return {
        "id": user.id,
        "name": user.name,
        "phone_masked": mask_phone(user.phone),  # FR-9.4 everywhere, even on own profile
        "notify_nearby": user.notify_nearby,
        "nearby_radius_km": user.nearby_radius_km,
        "lat": user.lat,
        "lng": user.lng,
        "trust": trust_payload(db, user.id),
        "created_at": iso(user.created_at),
        "volunteer": None if v is None else {
            "is_active": v.is_active,
            "skills": [{"skill": s.skill, "evidence": s.evidence, "verified_experience": s.verified_experience}
                       for s in v.skills],
            "completion_count": v.completion_count,
            "disaster_experience": v.disaster_experience or {},
            "stats": volunteer_stats(db, user),
        },
    }


@router.get("")
def get_me(user: User = Depends(current_user), db: Session = Depends(get_db)):
    return user_payload(db, user)


@router.patch("")
def patch_me(body: ProfilePatch, user: User = Depends(current_user), db: Session = Depends(get_db)):
    for field, value in body.model_dump(exclude_none=True).items():
        setattr(user, field, value.strip() if isinstance(value, str) else value)
    db.commit()
    return user_payload(db, user)


@router.post("/volunteer")
def upsert_volunteer(body: VolunteerIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Activate the volunteer layer or replace its skill list (FR-1.3 / FR-1.4).
    Experience already earned on a skill is kept when the skill stays."""
    wanted = {s.skill.strip(): s for s in body.skills if s.skill.strip()}
    if not wanted:
        raise HTTPException(422, "Tambahkan minimal satu kemampuan.")
    profile = user.volunteer
    if profile is None:
        profile = VolunteerProfile(user_id=user.id, is_active=body.is_active)
        db.add(profile)
        db.flush()
        db.refresh(user)
    existing = {s.skill.lower(): s for s in profile.skills}
    keep = []
    for name, s in wanted.items():
        row = existing.get(name.lower())
        if row is None:
            row = VolunteerSkill(user_id=user.id, skill=name, evidence=s.evidence)
        else:
            row.evidence = s.evidence
        keep.append(row)
    profile.skills = keep
    if body.is_active and not profile.is_active:
        profile.available_since = utcnow()
    profile.is_active = body.is_active
    db.commit()
    db.refresh(user)
    return user_payload(db, user)


@router.patch("/volunteer/active")
def set_active(body: ActiveIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """FR-1.6: pause/resume receiving requests without deleting the profile."""
    if user.volunteer is None:
        raise HTTPException(400, "Status relawan belum diaktifkan.")
    if body.is_active and not user.volunteer.is_active:
        user.volunteer.available_since = utcnow()
    user.volunteer.is_active = body.is_active
    db.commit()
    return user_payload(db, user)


@router.post("/location")
def update_location(body: LocationIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Latest device location: used for matching (FR-5.1) and live tracking (FR-8.5)."""
    user.lat, user.lng, user.location_updated_at = body.lat, body.lng, utcnow()
    db.commit()
    return {"ok": True}


@router.post("/device-token")
def device_token(body: TokenIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    user.fcm_token = body.token
    db.commit()
    return {"ok": True}


@router.get("/notifications")
def notifications(after_id: int = 0, limit: int = 50, user: User = Depends(current_user),
                  db: Session = Depends(get_db)):
    rows = db.scalars(select(Notification).where(Notification.user_id == user.id, Notification.id > after_id)
                      .order_by(Notification.id.desc()).limit(min(limit, 200))).all()
    unread = db.scalars(select(Notification.id).where(Notification.user_id == user.id,
                                                      Notification.read_at.is_(None))).all()
    return {
        "unread": len(unread),
        "items": [{"id": n.id, "kind": n.kind, "title": n.title, "body": n.body, "data": n.data,
                   "created_at": iso(n.created_at), "read": n.read_at is not None} for n in rows],
    }


@router.post("/notifications/read")
def mark_read(body: ReadIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    q = select(Notification).where(Notification.user_id == user.id, Notification.read_at.is_(None))
    if not body.all:
        q = q.where(Notification.id.in_(body.ids))
    now = utcnow()
    for n in db.scalars(q):
        n.read_at = now
    db.commit()
    return {"ok": True}


@router.get("/prompts")
def prompts(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Popups the app must show: 'sudah teratasi?' (5.11) and field-accuracy (FR-7.3)."""
    confirm = []
    rows = db.execute(
        select(Participant, Report).join(Report, Report.id == Participant.report_id)
        .where(Participant.user_id == user.id, Report.status == "active", Participant.excluded.is_(False),
               Participant.voted_done_at.is_(None), Participant.last_prompt_at.is_not(None))
    ).all()
    for p, r in rows:
        if p.last_response_at is None or p.last_response_at < p.last_prompt_at:
            confirm.append({"report_id": r.id, "address_text": r.address_text, "asked_at": iso(p.last_prompt_at)})

    accuracy = []
    done = db.execute(
        select(Assignment, Report).join(Report, Report.id == Assignment.report_id)
        .where(Assignment.volunteer_id == user.id, Assignment.status == "selesai")
    ).all()
    for a, r in done:
        answered = db.scalar(select(AccuracyFeedback).where(AccuracyFeedback.report_id == r.id,
                                                            AccuracyFeedback.user_id == user.id))
        if answered is None:
            accuracy.append({"report_id": r.id, "address_text": r.address_text, "raw_text": r.raw_text[:200]})
    return {"confirm": confirm, "accuracy": accuracy}
