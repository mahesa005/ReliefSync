"""Collective confirmation of 'Selesai' (FR-7.2 - FR-7.4, context doc 4.12 / 4.13 / 5.11).

* Voters: the reporter + every volunteer recorded on the report (not released).
* One action only: 'Konfirmasi Selesai' (no two-way voting). 'Belum' answers only
  mark the person as still active.
* From the first volunteer arrival, a periodic popup asks each voter "Apakah
  bencana ini sudah teratasi?". Someone who ignores a whole period is AFK and
  leaves the quorum population (not counted as 'no').
* Quorum is computed over active (non-AFK) voters. Default mode "proportional"
  uses the T(N) table of Section 4.13; mode "simple" uses 5.11 (3 people below 4,
  else 50%). Either way at least ``min_confirm_sources`` (2) distinct people are
  required when that many exist (FR-7.2: never a single source).
  -> Open Item #2: switch with the ``quorum_mode`` config key.
* 24 h after the report was received it resolves automatically (FR-7.4).
* On resolution the experience/history update of 4.12 runs, then volunteers are
  asked whether the field matched the report (FR-7.3 -> trust score).
"""
import math
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..core.app_config import Cfg
from ..db.models import Assignment, Need, Offer, Participant, Report, User, VolunteerProfile, utcnow
from .dispatch import DispatchError, incident_label
from .notify import notify


def threshold_proportional(n: int) -> int:
    if n <= 0:
        return 0
    if n <= 3:
        return n
    if n <= 10:
        return math.ceil(0.70 * n)
    if n <= 20:
        return math.ceil(0.60 * n)
    if n <= 50:
        return max(12, math.ceil(0.50 * n))
    if n <= 100:
        return max(25, math.ceil(0.40 * n))
    return math.ceil(0.40 * n)


def threshold_simple(n: int) -> int:
    if n <= 0:
        return 0
    return min(3, n) if n < 4 else math.ceil(0.5 * n)


def required_votes(n_active: int, cfg: Cfg) -> int:
    base = threshold_simple(n_active) if cfg["quorum_mode"] == "simple" else threshold_proportional(n_active)
    return max(base, min(int(cfg["min_confirm_sources"]), n_active))


def _participants(db: Session, report_id: str) -> list[Participant]:
    return db.scalars(select(Participant).where(Participant.report_id == report_id,
                                                Participant.excluded.is_(False))).all()


def quorum_state(db: Session, report: Report, cfg: Cfg | None = None) -> dict:
    cfg = cfg or Cfg(db)
    people = _participants(db, report.id)
    active = [p for p in people if not p.afk]
    votes = sum(1 for p in active if p.voted_done_at is not None)
    needed = required_votes(len(active), cfg)
    return {
        "participants": len(people),
        "active": len(active),
        "afk": len(people) - len(active),
        "votes": votes,
        "required": needed,
        "mode": cfg["quorum_mode"],
        "reached": len(active) > 0 and votes >= needed,
    }


def vote(db: Session, report: Report, user: User, done: bool, now: datetime | None = None) -> dict:
    now = now or utcnow()
    if report.status != "active":
        raise DispatchError("Laporan ini sudah tidak aktif.")
    p = db.scalar(select(Participant).where(Participant.report_id == report.id, Participant.user_id == user.id,
                                            Participant.excluded.is_(False)))
    if p is None:
        raise DispatchError("Hanya pelapor dan relawan yang terlibat yang dapat mengonfirmasi.", 403)
    p.last_response_at = now
    p.afk = False
    if done and p.voted_done_at is None:
        p.voted_done_at = now
    db.flush()
    check_quorum(db, report, now)
    return quorum_state(db, report)


def check_quorum(db: Session, report: Report, now: datetime) -> bool:
    if report.status == "active" and quorum_state(db, report)["reached"]:
        resolve(db, report, "quorum", now)
        return True
    return False


def mark_arrival(db: Session, report: Report, now: datetime) -> None:
    if report.resolution_started_at is None:
        report.resolution_started_at = now


def resolve(db: Session, report: Report, by: str, now: datetime | None = None) -> None:
    now = now or utcnow()
    report.status = "resolved"
    report.resolved_at = now
    report.resolved_by = by
    for need in db.scalars(select(Need).where(Need.report_id == report.id)):
        need.status = "selesai"
    for offer in db.scalars(select(Offer).where(Offer.report_id == report.id,
                                                Offer.status.in_(("pending", "rejected")))):
        offer.status = "closed"

    label = incident_label(report)
    assignments = db.scalars(select(Assignment).where(Assignment.report_id == report.id,
                                                      Assignment.status == "aktif")).all()
    for a in assignments:
        a.status = "selesai"
        apply_experience(db, a, report.incident_type)
        volunteer = db.get(User, a.volunteer_id)
        notify(db, volunteer, "accuracy_prompt", "Kejadian dinyatakan selesai",
               "Apakah kondisi di lapangan sesuai dengan laporan awal?", {"report_id": report.id})
    reporter = db.get(User, report.reporter_id)
    reason = "dikonfirmasi bersama" if by == "quorum" else "otomatis setelah 24 jam"
    notify(db, reporter, "info", f"{label} dinyatakan selesai", f"Status selesai {reason}. Terima kasih.",
           {"report_id": report.id})
    db.flush()


def apply_experience(db: Session, a: Assignment, disaster_type: str) -> None:
    """Section 4.12 -- run only after the disaster is resolved."""
    profile = db.get(VolunteerProfile, a.volunteer_id)
    if profile is None:
        return
    exp = dict(profile.disaster_experience or {})
    exp[disaster_type] = exp.get(disaster_type, 0) + 1
    profile.disaster_experience = exp  # reassign so the JSON change is persisted
    if a.role == "utama":
        profile.completion_count += 1
        need = db.get(Need, a.need_id)
        for s in profile.skills:
            if s.skill_id == need.skill_id:
                s.verified_experience += 1
                break


def tick(db: Session, now: datetime | None = None) -> None:
    now = now or utcnow()
    cfg = Cfg(db)
    interval = timedelta(seconds=int(cfg["confirm_prompt_interval_seconds"]))
    deadline = timedelta(hours=float(cfg["auto_resolve_hours"]))
    for report in db.scalars(select(Report).where(Report.status == "active")).all():
        if now - report.received_at >= deadline:
            resolve(db, report, "timeout", now)
            continue
        if report.resolution_started_at is None:
            continue
        for p in _participants(db, report.id):
            if p.voted_done_at is not None:
                continue
            if p.last_prompt_at is None or now - p.last_prompt_at >= interval:
                ignored = p.last_prompt_at is not None and (
                    p.last_response_at is None or p.last_response_at < p.last_prompt_at)
                if ignored:
                    p.afk = True
                p.last_prompt_at = now
                user = db.get(User, p.user_id)
                if not user.is_simulated:
                    notify(db, user, "confirm_prompt", "Apakah bencana ini sudah teratasi?",
                           f"{incident_label(report)} -- jawab Ya / Belum.", {"report_id": report.id})
        db.flush()
        check_quorum(db, report, now)


def pending_prompt(db: Session, report: Report, user_id: str) -> bool:
    """True when this user currently has an unanswered 'sudah teratasi?' popup."""
    p = db.scalar(select(Participant).where(Participant.report_id == report.id, Participant.user_id == user_id,
                                            Participant.excluded.is_(False)))
    if p is None or p.voted_done_at is not None or p.last_prompt_at is None:
        return False
    return p.last_response_at is None or p.last_response_at < p.last_prompt_at
