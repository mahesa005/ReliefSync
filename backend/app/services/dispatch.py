"""Dispatcher: needs -> candidates -> batch alarms -> assignments
(FR-5.x, FR-6.x, context doc 4.10 / 4.11).

Batch model (Section 4.10; Open Item #14 resolved in its favour):
  * When a need starts, every ranked candidate gets an Offer. Batch 1 (size =
    Required Need) gets an ALARM; everyone else gets a STANDARD notification and
    may accept proactively at any time (FR-5.7 / FR-5.8).
  * The alarm is loud for ``alarm_seconds`` (30 s). If the need is still not full
    when it ends -- or earlier, if everyone in the active batch has rejected
    (FR-5.10) -- the next batch is alarmed:
        B2 = Remaining Need, B3+ = min(Remaining Need * 2^k, candidates left).
  * When every candidate has been alarmed and the quota is still open the need is
    marked ``exhausted`` and stays visible as open (FR-5.14 / NFR-12).

Role on accept (4.11):
  * accepted within ``response_window_seconds`` (5 min) of the own alarm -> utama
    (excess acceptors stay utama);
  * proactive accept before the own alarm while the need is still open -> utama;
  * after the window, after the need was already full, or after an earlier
    reject -> tambahan.
Remaining Need counts every active acceptor, so Tambahan help also fills the quota.
"""
from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from ..core.app_config import Cfg
from ..db.models import (
    Assignment,
    NearbyNotice,
    Need,
    Offer,
    Participant,
    Report,
    User,
    VolunteerProfile,
    utcnow,
)
from . import matching
from .geo import haversine_km
from .notify import notify
from .trust import trust_payload


class DispatchError(Exception):
    def __init__(self, message: str, status_code: int = 409):
        super().__init__(message)
        self.message = message
        self.status_code = status_code


INCIDENT_LABELS = {"kebakaran": "Kebakaran permukiman", "banjir": "Banjir", "longsor": "Tanah longsor",
                   "gempa": "Gempa bumi"}


def incident_label(report: Report) -> str:
    return INCIDENT_LABELS.get(report.incident_type, report.incident_type.title())


# ---------------------------------------------------------------------------
# Candidate pool
# ---------------------------------------------------------------------------
def volunteer_inputs(db: Session) -> list[matching.VolunteerInput]:
    # selectinload: one extra query for every profile's skills, instead of one
    # lazy-load query PER profile (N+1) -- against a remote Supabase pooler
    # that N+1 alone took 5-6s for ~30 volunteers and was the main reason
    # confirming a report timed out client-side.
    rows = db.execute(
        select(VolunteerProfile, User).join(User, User.id == VolunteerProfile.user_id)
        .where(VolunteerProfile.is_active.is_(True))
        .options(selectinload(VolunteerProfile.skills))
    ).all()
    return [
        matching.VolunteerInput(
            user_id=user.id,
            lat=user.lat,
            lng=user.lng,
            is_active=profile.is_active,
            skills={s.skill_id: (s.evidence, s.verified_experience) for s in profile.skills},
            completion_count=profile.completion_count,
            disaster_experience=dict(profile.disaster_experience or {}),
            selection_count=profile.selection_count,
            available_since=profile.available_since,
        )
        for profile, user in rows
    ]


def rank_for_need(db: Session, need: Need, report: Report, cfg: Cfg,
                  volunteers: list[matching.VolunteerInput] | None = None) -> list[matching.Candidate]:
    return matching.rank_candidates(
        volunteers if volunteers is not None else volunteer_inputs(db),
        need.skill_id, report.incident_type, report.lat, report.lng, cfg,
        exclude_user_ids={report.reporter_id},
    )


# ---------------------------------------------------------------------------
# Report activation
# ---------------------------------------------------------------------------
def ensure_participant(db: Session, report_id: str, user_id: str, role: str) -> Participant:
    p = db.scalar(select(Participant).where(Participant.report_id == report_id, Participant.user_id == user_id))
    if p is None:
        p = Participant(report_id=report_id, user_id=user_id, role=role)
        db.add(p)
        db.flush()
    return p


def activate_report(db: Session, report: Report, needs_spec: list[dict], now: datetime | None = None) -> None:
    """Called once the reporter confirmed the extraction (FR-3.5)."""
    now = now or utcnow()
    cfg = Cfg(db)
    report.status = "active"
    report.confirmed_at = now
    ensure_participant(db, report.id, report.reporter_id, "pelapor")
    # Both computed once for the whole report, not once per need/candidate: the
    # eligible-volunteer pool and the reporter's trust tier can't change
    # mid-request, and each is a query of its own. Redoing them per need/offer
    # was the actual cause of confirm-report timing out against a remote
    # Supabase pooler (~30 volunteers x 3 needs = ~90 avoidable round trips).
    trust = trust_payload(db, report.reporter_id, cfg)
    volunteers = volunteer_inputs(db)
    # Preload every candidate's User row in one query. Looking each one up with
    # db.get() inside the notification loop below did two costly things at
    # once: ~15-30 extra round trips, AND each SELECT forces SQLAlchemy's
    # autoflush, which serialised every pending Offer/Notification write into
    # its own round trip too -- that combination was the actual 30s+ cost.
    users_by_id = {u.id: u for u in db.scalars(select(User).where(User.id.in_([v.user_id for v in volunteers])))}
    notified: set[str] = set()
    for spec in needs_spec:
        need = Need(report_id=report.id, skill_id=spec["skill_id"],
                    quota=max(1, int(spec["quota"])), created_at=now)
        db.add(need)
        db.flush()
        start_need(db, need, report, cfg, now, notified, trust, volunteers, users_by_id)
    notify_nearby_users(db, report, cfg, now)
    db.flush()


def start_need(db: Session, need: Need, report: Report, cfg: Cfg, now: datetime,
               notified: set[str] | None = None, trust: dict | None = None,
               volunteers: list[matching.VolunteerInput] | None = None,
               users_by_id: dict[str, User] | None = None) -> None:
    notified = notified if notified is not None else set()
    trust = trust if trust is not None else trust_payload(db, report.reporter_id, cfg)
    ranked = rank_for_need(db, need, report, cfg, volunteers)
    for rank, c in enumerate(ranked, start=1):
        db.add(Offer(need_id=need.id, report_id=report.id, volunteer_id=c.user_id, rank=rank,
                     score=c.score, distance_km=c.distance_km, notified_at=now))
    db.flush()
    if not ranked:
        need.exhausted = True  # NFR-12: surfaced as open, never silently failed
        refresh_need_status(db, need)
        return
    activate_next_batch(db, need, report, cfg, now, trust, users_by_id)
    # Everyone not in batch 1 gets a standard (non-alarm) notification (FR-5.7).
    for offer in db.scalars(select(Offer).where(Offer.need_id == need.id, Offer.batch_number.is_(None))):
        if offer.volunteer_id in notified:
            continue
        notified.add(offer.volunteer_id)
        user = (users_by_id or {}).get(offer.volunteer_id) or db.get(User, offer.volunteer_id)
        _send_offer_notification(db, offer, need, report, cfg, user, alarm=False, trust=trust)


def notify_nearby_users(db: Session, report: Report, cfg: Cfg, now: datetime) -> None:
    """Ask people around the incident to confirm they see it (5.7). Opt-out: FR-1.7.
    Volunteers who already got an offer for this report are not pinged twice."""
    offered = set(db.scalars(select(Offer.volunteer_id).where(Offer.report_id == report.id)))
    users = db.scalars(select(User).where(User.notify_nearby.is_(True), User.lat.is_not(None),
                                          User.id != report.reporter_id, User.is_simulated.is_(False)))
    for u in users:
        d = haversine_km(u.lat, u.lng, report.lat, report.lng)
        if d > u.nearby_radius_km:
            continue
        db.add(NearbyNotice(report_id=report.id, user_id=u.id, created_at=now))
        if u.id not in offered:
            notify(db, u, "nearby", f"{incident_label(report)} di sekitar Anda ({d:.1f} km)",
                   "Apakah Anda melihat kejadian ini? Ketuk untuk konfirmasi.",
                   {"report_id": report.id, "distance_km": round(d, 2)})


# ---------------------------------------------------------------------------
# Batches
# ---------------------------------------------------------------------------
def accepted_count(db: Session, need_id: str) -> int:
    return db.scalar(select(func.count()).select_from(Assignment)
                     .where(Assignment.need_id == need_id, Assignment.status != "dilepas")) or 0


def remaining_need(db: Session, need: Need) -> int:
    return max(0, need.quota - accepted_count(db, need.id))


def refresh_need_status(db: Session, need: Need) -> None:
    if need.status == "selesai":
        return
    n = accepted_count(db, need.id)
    need.status = "penuh" if n >= need.quota else ("sebagian" if n > 0 else "belum_ada")


def activate_next_batch(db: Session, need: Need, report: Report, cfg: Cfg, now: datetime,
                        trust: dict | None = None, users_by_id: dict[str, User] | None = None) -> bool:
    """Alarm the next batch. Returns False when no candidate is left (exhausted)."""
    trust = trust if trust is not None else trust_payload(db, report.reporter_id, cfg)
    remaining = remaining_need(db, need)
    waiting = db.scalars(
        select(Offer).where(Offer.need_id == need.id, Offer.batch_number.is_(None), Offer.status == "pending")
        .order_by(Offer.rank)
    ).all()
    if not waiting:
        need.exhausted = True
        refresh_need_status(db, need)
        return False
    number = need.current_batch + 1
    size = matching.batch_size(number, remaining, len(waiting))
    for offer in waiting[:size]:
        offer.batch_number = number
        offer.alarm_sent_at = now
        user = (users_by_id or {}).get(offer.volunteer_id) or db.get(User, offer.volunteer_id)
        _send_offer_notification(db, offer, need, report, cfg, user, alarm=True, trust=trust)
    need.current_batch = number
    need.batch_sent_at = now
    if len(waiting) <= size:
        need.exhausted = True  # every candidate has now been alarmed
    return True


def _send_offer_notification(db: Session, offer: Offer, need: Need, report: Report, cfg: Cfg, user: User,
                             alarm: bool, trust: dict) -> None:
    need_label = need.skill.name
    title = ("🚨 ALARM: " if alarm else "") + f"{incident_label(report)} {offer.distance_km:.1f} km dari Anda"
    body = f"Dibutuhkan: {need_label}. Pelapor: {trust['label']}."
    notify(db, user, "alarm" if alarm else "standard", title, body, {
        "report_id": report.id, "need_id": need.id, "offer_id": offer.id,
        "distance_km": offer.distance_km, "skill_id": need.skill_id, "skill": need_label,
        "trust_tier": trust["tier"], "trust_label": trust["label"],
        "alarm_seconds": int(cfg["alarm_seconds"]) if alarm else 0,
    })


# ---------------------------------------------------------------------------
# Accept / reject / participate
# ---------------------------------------------------------------------------
def _decide_role(db: Session, offer: Offer, need: Need, cfg: Cfg, now: datetime) -> str:
    if offer.rejected_before:
        return "tambahan"
    if offer.alarm_sent_at is not None:
        in_window = now - offer.alarm_sent_at <= timedelta(seconds=int(cfg["response_window_seconds"]))
        return "utama" if in_window else "tambahan"
    if offer.proactive:
        return "tambahan"
    return "utama" if remaining_need(db, need) > 0 else "tambahan"


def accept_offer(db: Session, offer: Offer, now: datetime | None = None) -> Assignment:
    now = now or utcnow()
    cfg = Cfg(db)
    report = db.get(Report, offer.report_id)
    if report is None or report.status != "active":
        raise DispatchError("Laporan ini sudah tidak aktif.")
    existing = db.scalar(select(Assignment).where(Assignment.report_id == report.id,
                                                  Assignment.volunteer_id == offer.volunteer_id))
    if existing is not None:
        if existing.status == "dilepas":
            raise DispatchError("Anda sudah dilepas dari laporan ini oleh pelapor.")
        return existing
    if offer.status == "closed":
        raise DispatchError("Tawaran ini sudah ditutup.")

    need = db.get(Need, offer.need_id)
    role = _decide_role(db, offer, need, cfg, now)
    order = (db.scalar(select(func.max(Assignment.order_number)).where(Assignment.need_id == need.id)) or 0) + 1
    assignment = Assignment(need_id=need.id, report_id=report.id, volunteer_id=offer.volunteer_id,
                            role=role, order_number=order, accepted_at=now)
    db.add(assignment)
    offer.status = "accepted"
    offer.responded_at = now

    # One volunteer helps one need per report: close their other offers here.
    for other in db.scalars(select(Offer).where(Offer.report_id == report.id,
                                                Offer.volunteer_id == offer.volunteer_id,
                                                Offer.id != offer.id,
                                                Offer.status.in_(("pending", "rejected")))):
        other.status = "closed"

    profile = db.get(VolunteerProfile, offer.volunteer_id)
    if profile is not None:
        profile.selection_count += 1
    ensure_participant(db, report.id, offer.volunteer_id, "relawan")
    db.flush()
    refresh_need_status(db, need)

    reporter = db.get(User, report.reporter_id)
    volunteer = db.get(User, offer.volunteer_id)
    notify(db, reporter, "info", f"{volunteer.name} menuju lokasi",
           f"Relawan ke-{order} untuk {need.skill.name} "
           f"({'Bantuan Utama' if role == 'utama' else 'Bantuan Tambahan'}).",
           {"report_id": report.id})
    return assignment


def reject_offer(db: Session, offer: Offer, now: datetime | None = None) -> Offer:
    """FR-6.3: closes this offer only; it stays in the request list and can be
    accepted later (as Bantuan Tambahan)."""
    if offer.status == "accepted":
        raise DispatchError("Tawaran sudah diterima.")
    offer.status = "rejected"
    offer.rejected_before = True
    offer.responded_at = now or utcnow()
    return offer


def participate(db: Session, report: Report, user: User, now: datetime | None = None) -> Assignment:
    """'Partisipasi sebagai relawan' from the map (5.4): reuse an existing offer if
    the system already picked this volunteer, else join the best-fitting need."""
    now = now or utcnow()
    if report.reporter_id == user.id:
        raise DispatchError("Anda adalah pelapor kejadian ini.", 400)
    if user.volunteer is None or not user.volunteer.is_active:
        raise DispatchError("Aktifkan status relawan terlebih dahulu.", 400)
    offers = db.scalars(select(Offer).where(Offer.report_id == report.id, Offer.volunteer_id == user.id,
                                            Offer.status.in_(("pending", "rejected")))
                        .order_by(Offer.rank)).all()
    if offers:
        return accept_offer(db, offers[0], now)

    skills = {s.skill_id for s in user.volunteer.skills}
    needs = [n for n in report.needs if n.status != "selesai"]
    if not needs:
        raise DispatchError("Laporan ini tidak memiliki kebutuhan terbuka.")
    needs.sort(key=lambda n: (n.skill_id not in skills, -remaining_need(db, n)))
    need = needs[0]
    d = haversine_km(user.lat, user.lng, report.lat, report.lng) if user.lat is not None else 0.0
    last_rank = db.scalar(select(func.max(Offer.rank)).where(Offer.need_id == need.id)) or 0
    offer = db.scalar(select(Offer).where(Offer.need_id == need.id, Offer.volunteer_id == user.id))
    if offer is None:
        offer = Offer(need_id=need.id, report_id=report.id, volunteer_id=user.id, rank=last_rank + 1,
                      score=0.0, distance_km=round(d, 3), notified_at=now, proactive=True)
        db.add(offer)
        db.flush()
    return accept_offer(db, offer, now)


def release_assignment(db: Session, assignment: Assignment) -> None:
    """Reporter releases a volunteer (4.11: volunteers cannot cancel themselves)."""
    assignment.status = "dilepas"
    p = db.scalar(select(Participant).where(Participant.report_id == assignment.report_id,
                                            Participant.user_id == assignment.volunteer_id))
    if p is not None:
        p.excluded = True
    need = db.get(Need, assignment.need_id)
    db.flush()
    refresh_need_status(db, need)
    if need.status != "penuh":
        need.exhausted = False if _has_waiting(db, need) else need.exhausted


def _has_waiting(db: Session, need: Need) -> bool:
    return db.scalar(select(func.count()).select_from(Offer).where(
        Offer.need_id == need.id, Offer.batch_number.is_(None), Offer.status == "pending")) > 0


# ---------------------------------------------------------------------------
# Engine tick: escalation (FR-5.9 / FR-5.10)
# ---------------------------------------------------------------------------
def tick(db: Session, now: datetime | None = None) -> None:
    now = now or utcnow()
    cfg = Cfg(db)
    alarm_window = timedelta(seconds=int(cfg["alarm_seconds"]))
    needs = db.scalars(
        select(Need).join(Report, Report.id == Need.report_id)
        .where(Report.status == "active", Need.status.in_(("belum_ada", "sebagian")), Need.exhausted.is_(False))
    ).all()
    for need in needs:
        refresh_need_status(db, need)
        if need.status == "penuh":
            continue
        batch = db.scalars(select(Offer).where(Offer.need_id == need.id,
                                               Offer.batch_number == need.current_batch)).all()
        all_rejected = bool(batch) and all(o.status in ("rejected", "closed") for o in batch)
        timed_out = need.batch_sent_at is None or now - need.batch_sent_at >= alarm_window
        if timed_out or (all_rejected and cfg["escalate_on_all_reject"]):
            activate_next_batch(db, need, need.report, cfg, now)
