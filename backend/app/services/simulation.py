"""Simulated volunteer data for the demo (MVP scope: data relawan simulasi).

* ``seed_demo`` creates ~30 simulated volunteers around a centre point plus two
  real demo accounts (reporter + volunteer) that can log in from the app.
* ``relocate`` moves the simulated volunteers around any point, so the demo
  works wherever the presenter's phone is.
* ``tick`` makes simulated volunteers behave: answer alarms after a few seconds
  (accept with ``sim_accept_probability``), travel to the incident, answer the
  'sudah teratasi?' popup and eventually confirm, and give accuracy feedback.
  Real users are never touched.
"""
import hashlib
import random
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..core.app_config import Cfg
from ..core.security import hash_password
from ..db.models import (
    AccuracyFeedback,
    Assignment,
    Offer,
    Participant,
    Report,
    Skill,
    User,
    VolunteerProfile,
    VolunteerSkill,
    utcnow,
)
from . import confirmation, dispatch
from .geo import move_towards, offset_point

# Default demo centre: a dense residential area in Jakarta Barat (Tambora).
DEMO_CENTER = (-6.1470, 106.8055)

SIM_NAMES = [
    "Andi Pratama", "Budi Santoso", "Citra Lestari", "Dewi Anggraini", "Eko Saputra", "Fajar Nugroho",
    "Gita Permata", "Hendra Wijaya", "Indah Sari", "Joko Susilo", "Kartika Putri", "Lukman Hakim",
    "Maya Rahmawati", "Nanda Firmansyah", "Oktaviani", "Putra Ramadhan", "Qori Amalia", "Rizky Maulana",
    "Siti Nurhaliza", "Taufik Hidayat", "Umi Kalsum", "Vina Oktavia", "Wahyu Setiawan", "Yusuf Ibrahim",
    "Zahra Aulia", "Agus Salim", "Bayu Aji", "Dimas Aditya", "Fitri Handayani", "Galih Prakoso",
]
DEMO_PASSWORD = "demo1234"
DEMO_ACCOUNTS = [
    # phone, name, volunteer skill names (None = reporter only) -- resolved to skill_id in seed_demo
    ("081200000001", "Demo Pelapor", None),
    ("081200000002", "Demo Relawan", ["Teknik memindahkan korban", "P3K", "Penggunaan APAR"]),
]


def _h(*parts: str) -> int:
    return int(hashlib.sha256("|".join(parts).encode()).hexdigest(), 16)


def _sim_offset(user_id: str) -> tuple[float, float]:
    """Stable (distance_km, bearing) for a simulated volunteer. ~10% sit outside
    the 5 km hard filter on purpose, to show it working."""
    h = _h(user_id)
    distance = 0.2 + (h % 1000) / 1000 * 4.6
    if h % 10 == 0:
        distance = 5.5 + (h % 7) * 0.3
    return distance, (h // 1000) % 360


def seed_demo(db: Session) -> None:
    if db.scalar(select(User).where(User.is_simulated.is_(True)).limit(1)) is not None:
        return
    skill_by_name = {s.name: s.id for s in db.scalars(select(Skill))}
    skill_ids = list(skill_by_name.values())
    if not skill_ids:
        raise RuntimeError("Skill catalog must be seeded before demo volunteers (call skills.seed_skills first).")
    rng = random.Random(2026)
    now = utcnow()
    for i, name in enumerate(SIM_NAMES):
        phone = f"0899{i:08d}"
        user = User(name=name, phone=phone, password_hash="!", phone_verified=True, is_simulated=True,
                    notify_nearby=False)
        db.add(user)
        db.flush()
        dist, bearing = _sim_offset(user.id)
        user.lat, user.lng = offset_point(*DEMO_CENTER, dist, bearing)
        user.location_updated_at = now
        profile = VolunteerProfile(
            user_id=user.id, is_active=rng.random() > 0.1,
            available_since=now - timedelta(minutes=rng.randint(1, 600)),
            completion_count=rng.choice([0, 0, 1, 2, 3, 5, 8]),
            selection_count=rng.randint(0, 6),
            disaster_experience={"kebakaran": rng.choice([0, 0, 1, 2, 4])},
        )
        db.add(profile)
        for skill_id in rng.sample(skill_ids, min(rng.randint(1, 3), len(skill_ids))):
            db.add(VolunteerSkill(user_id=user.id, skill_id=skill_id,
                                  evidence="certified" if rng.random() < 0.35 else "self_declared",
                                  verified_experience=rng.choice([0, 0, 1, 2, 3, 6])))

    for phone, name, skill_names in DEMO_ACCOUNTS:
        if db.scalar(select(User).where(User.phone == phone)) is not None:
            continue
        lat, lng = offset_point(*DEMO_CENTER, 0.8, 45 if skill_names else 200)
        user = User(name=name, phone=phone, password_hash=hash_password(DEMO_PASSWORD), phone_verified=True,
                    lat=lat, lng=lng, location_updated_at=now)
        db.add(user)
        db.flush()
        if skill_names:
            db.add(VolunteerProfile(user_id=user.id, is_active=True, available_since=now))
            for skill_name in skill_names:
                db.add(VolunteerSkill(user_id=user.id, skill_id=skill_by_name[skill_name],
                                      evidence="certified", verified_experience=2))
    db.commit()


def relocate(db: Session, lat: float, lng: float) -> int:
    sims = db.scalars(select(User).where(User.is_simulated.is_(True))).all()
    now = utcnow()
    busy = set(db.scalars(select(Assignment.volunteer_id).join(Report, Report.id == Assignment.report_id)
                          .where(Report.status == "active")))
    moved = 0
    for u in sims:
        if u.id in busy:
            continue
        dist, bearing = _sim_offset(u.id)
        u.lat, u.lng = offset_point(lat, lng, dist, bearing)
        u.location_updated_at = now
        moved += 1
    db.commit()
    return moved


def tick(db: Session, now: datetime | None = None) -> None:
    now = now or utcnow()
    cfg = Cfg(db)
    if not cfg["sim_auto_respond"]:
        return
    _answer_alarms(db, cfg, now)
    _move_and_vote(db, cfg, now)
    _accuracy_feedback(db, now)


def _answer_alarms(db: Session, cfg: Cfg, now: datetime) -> None:
    offers = db.execute(
        select(Offer, User).join(User, User.id == Offer.volunteer_id)
        .join(Report, Report.id == Offer.report_id)
        .where(User.is_simulated.is_(True), Offer.status == "pending", Offer.alarm_sent_at.is_not(None),
               Report.status == "active")
    ).all()
    p_accept = float(cfg["sim_accept_probability"])
    for offer, _user in offers:
        if offer.status != "pending":  # closed by an accept earlier in this loop
            continue
        h = _h(offer.id)
        delay = 3 + h % 18  # 3..20 s: inside the 30 s alarm, like a real person
        if now - offer.alarm_sent_at < timedelta(seconds=delay):
            continue
        if (h // 100) % 100 < p_accept * 100:
            try:
                dispatch.accept_offer(db, offer, now)
            except dispatch.DispatchError:
                offer.status = "closed"
        else:
            dispatch.reject_offer(db, offer, now)


def _move_and_vote(db: Session, cfg: Cfg, now: datetime) -> None:
    rows = db.execute(
        select(Assignment, User, Report).join(User, User.id == Assignment.volunteer_id)
        .join(Report, Report.id == Assignment.report_id)
        .where(User.is_simulated.is_(True), Assignment.status == "aktif", Report.status == "active")
    ).all()
    speed = float(cfg["sim_speed_mps"])
    vote_after = timedelta(seconds=int(cfg["sim_vote_after_arrival_seconds"]))
    for a, user, report in rows:
        if a.travel_status == "otw":
            last = max(user.location_updated_at or a.accepted_at, a.accepted_at)
            seconds = max(0.0, (now - last).total_seconds())
            user.lat, user.lng, arrived = move_towards(user.lat, user.lng, report.lat, report.lng, speed * seconds)
            user.location_updated_at = now
            if arrived:
                a.travel_status = "sampai"
                a.arrived_at = now
                confirmation.mark_arrival(db, report, now)
            continue
        p = db.scalar(select(Participant).where(Participant.report_id == report.id,
                                                Participant.user_id == user.id))
        if p is None or p.voted_done_at is not None:
            continue
        if a.arrived_at and now - a.arrived_at >= vote_after:
            confirmation.vote(db, report, user, True, now)
            if report.status != "active":
                return
        elif p.last_prompt_at and (p.last_response_at is None or p.last_response_at < p.last_prompt_at):
            p.last_response_at = now  # answers "Belum" -> stays active


def _accuracy_feedback(db: Session, now: datetime) -> None:
    rows = db.execute(
        select(Assignment, Report).join(User, User.id == Assignment.volunteer_id)
        .join(Report, Report.id == Assignment.report_id)
        .where(User.is_simulated.is_(True), Assignment.status == "selesai",
               Report.resolved_at >= now - timedelta(hours=1))
    ).all()
    for a, report in rows:
        exists = db.scalar(select(AccuracyFeedback).where(AccuracyFeedback.report_id == report.id,
                                                          AccuracyFeedback.user_id == a.volunteer_id))
        if exists is None:
            db.add(AccuracyFeedback(report_id=report.id, reporter_id=report.reporter_id,
                                    user_id=a.volunteer_id, matches=True, created_at=now))
