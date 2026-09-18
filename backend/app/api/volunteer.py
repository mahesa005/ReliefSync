"""Volunteer side: request list, accept/reject, active task (FR-5.x, FR-6.x, FR-7.1, FR-8.2, FR-8.6)."""
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..app_config import Cfg
from ..db import get_db
from ..models import Assignment, Need, Offer, Participant, Report, User, utcnow
from ..security import mask_phone
from ..services import agencies, confirmation, dispatch
from ..services.geo import haversine_km
from ..services.trust import trust_payload
from .deps import current_user, engine_lock, iso

router = APIRouter(tags=["volunteer"])


class TravelIn(BaseModel):
    status: Literal["otw", "sampai"]


def _require_volunteer(user: User) -> None:
    if user.volunteer is None:
        raise HTTPException(403, "Aktifkan status relawan terlebih dahulu.")


def offer_view(db: Session, offer: Offer, cfg: Cfg) -> dict:
    """What a volunteer may see about an offered report (NFR-15): description,
    location, the matched need and the reporter's trust tier -- not the reporter's
    identity or unmasked phone."""
    report = db.get(Report, offer.report_id)
    need = db.get(Need, offer.need_id)
    alarm_active = offer.alarm_sent_at is not None and offer.status == "pending" and (
        (utcnow() - offer.alarm_sent_at).total_seconds() < int(cfg["alarm_seconds"]))
    return {
        "offer_id": offer.id,
        "status": offer.status,
        "report_id": report.id,
        "report_status": report.status,
        "incident_label": dispatch.incident_label(report),
        "raw_text": report.raw_text,
        "address_text": report.address_text,
        "lat": report.lat, "lng": report.lng,
        "received_at": iso(report.received_at),
        "photo_urls": report.photo_urls or [],
        "distance_km": offer.distance_km,
        "need": {"id": need.id, "label": cfg["need_catalog"].get(need.category, {}).get("label", need.category),
                 "skill": need.skill, "quota": need.quota, "accepted": dispatch.accepted_count(db, need.id),
                 "status": need.status},
        "matched_skill": need.skill,
        "reporter_trust": trust_payload(db, report.reporter_id, cfg),  # FR-9.3
        "contact_phone_masked": mask_phone(report.contact_phone),
        "is_alarm": offer.batch_number is not None,
        "alarm_active": alarm_active,
        "alarm_sent_at": iso(offer.alarm_sent_at),
        "notified_at": iso(offer.notified_at),
        "batch_number": offer.batch_number,
        "rank": offer.rank,
        "rejected_before": offer.rejected_before,
    }


@router.get("/volunteer/requests")
def requests(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """'Permintaan relawan' widget: pending + rejected offers on active reports
    (rejected ones stay here and can still be accepted, 5.9)."""
    _require_volunteer(user)
    cfg = Cfg(db)
    offers = db.scalars(
        select(Offer).join(Report, Report.id == Offer.report_id)
        .where(Offer.volunteer_id == user.id, Offer.status.in_(("pending", "rejected")), Report.status == "active")
        .order_by(Offer.alarm_sent_at.desc().nulls_last(), Offer.notified_at.desc())
    ).all()
    seen, items = set(), []
    for o in offers:  # one entry per report (best-ranked need)
        if o.report_id in seen:
            continue
        seen.add(o.report_id)
        items.append(offer_view(db, o, cfg))
    items.sort(key=lambda i: (not i["alarm_active"], i["status"] == "rejected", i["distance_km"]))
    return items


@router.get("/offers/{offer_id}")
def get_offer(offer_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    offer = db.get(Offer, offer_id)
    if offer is None or offer.volunteer_id != user.id:
        raise HTTPException(404, "Tawaran tidak ditemukan.")
    return offer_view(db, offer, Cfg(db))


@router.post("/offers/{offer_id}/accept")
def accept(offer_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    offer = db.get(Offer, offer_id)
    if offer is None or offer.volunteer_id != user.id:
        raise HTTPException(404, "Tawaran tidak ditemukan.")
    with engine_lock:
        try:
            a = dispatch.accept_offer(db, offer)
        except dispatch.DispatchError as err:
            db.rollback()
            raise HTTPException(err.status_code, err.message) from None
        db.commit()
    return task_view(db, a, user)


@router.post("/offers/{offer_id}/reject")
def reject(offer_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    offer = db.get(Offer, offer_id)
    if offer is None or offer.volunteer_id != user.id:
        raise HTTPException(404, "Tawaran tidak ditemukan.")
    with engine_lock:
        try:
            dispatch.reject_offer(db, offer)
        except dispatch.DispatchError as err:
            raise HTTPException(err.status_code, err.message) from None
        dispatch.tick(db)  # FR-5.10: escalate at once if the whole batch said no
        db.commit()
    return {"ok": True}


def task_view(db: Session, a: Assignment, user: User) -> dict:
    report = db.get(Report, a.report_id)
    need = db.get(Need, a.need_id)
    cfg = Cfg(db)
    return {
        "id": a.id,
        "report_id": report.id,
        "report_status": report.status,
        "incident_label": dispatch.incident_label(report),
        "raw_text": report.raw_text,
        "address_text": report.address_text,
        "lat": report.lat, "lng": report.lng,
        "received_at": iso(report.received_at),
        "photo_urls": report.photo_urls or [],
        "role": a.role,
        "order_number": a.order_number,  # "relawan ke-N" (5.10)
        "skill": need.skill,
        "need_label": cfg["need_catalog"].get(need.category, {}).get("label", need.category),
        "need_quota": need.quota,
        "need_accepted": dispatch.accepted_count(db, need.id),
        "travel_status": a.travel_status,
        "status": a.status,
        "accepted_at": iso(a.accepted_at),
        "arrived_at": iso(a.arrived_at),
        "distance_km": round(haversine_km(user.lat, user.lng, report.lat, report.lng), 2)
        if user.lat is not None else None,
        "contact_phone_masked": mask_phone(report.contact_phone),
        "reporter_trust": trust_payload(db, report.reporter_id, cfg),
        "quorum": confirmation.quorum_state(db, report, cfg),
        "my_vote_done": _voted(db, report, user),
        "prompt_pending": confirmation.pending_prompt(db, report, user.id),
        "official_status": report.official_status,
        "agencies": agencies.suggest(db, report.incident_type, report.lat, report.lng),
    }


def _voted(db: Session, report: Report, user: User) -> bool:
    p = db.scalar(select(Participant).where(Participant.report_id == report.id, Participant.user_id == user.id))
    return p is not None and p.voted_done_at is not None


def _own_assignment(db: Session, assignment_id: str, user: User) -> Assignment:
    a = db.get(Assignment, assignment_id)
    if a is None or a.volunteer_id != user.id:
        raise HTTPException(404, "Tugas tidak ditemukan.")
    return a


@router.get("/volunteer/tasks")
def tasks(user: User = Depends(current_user), db: Session = Depends(get_db)):
    _require_volunteer(user)
    rows = db.scalars(select(Assignment).where(Assignment.volunteer_id == user.id)
                      .order_by(Assignment.accepted_at.desc()).limit(30)).all()
    return [task_view(db, a, user) for a in rows]


@router.get("/assignments/{assignment_id}")
def get_task(assignment_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    return task_view(db, _own_assignment(db, assignment_id, user), user)


@router.post("/assignments/{assignment_id}/travel-status")
def travel_status(assignment_id: str, body: TravelIn, user: User = Depends(current_user),
                  db: Session = Depends(get_db)):
    """'Masih di jalan' / 'Sudah sampai' (FR-7.1 / FR-8.6). 'Sudah teratasi' is the
    same action as the periodic popup -> POST /reports/{id}/vote."""
    a = _own_assignment(db, assignment_id, user)
    if a.status != "aktif":
        raise HTTPException(409, "Tugas ini sudah tidak aktif.")
    report = db.get(Report, a.report_id)
    with engine_lock:
        a.travel_status = body.status
        if body.status == "sampai":
            a.arrived_at = a.arrived_at or utcnow()
            confirmation.mark_arrival(db, report, utcnow())
        db.commit()
    return task_view(db, a, user)


@router.get("/volunteer/open-needs")
def open_needs(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """FR-8.2: open needs within reach (the 5 km matching radius)."""
    _require_volunteer(user)
    cfg = Cfg(db)
    if user.lat is None:
        return []
    max_km = float(cfg["max_distance_km"])
    out = []
    rows = db.execute(select(Need, Report).join(Report, Report.id == Need.report_id)
                      .where(Report.status == "active", Need.status.in_(("belum_ada", "sebagian")))).all()
    skills = {s.skill.lower() for s in user.volunteer.skills}
    for need, report in rows:
        if report.reporter_id == user.id:
            continue
        d = haversine_km(user.lat, user.lng, report.lat, report.lng)
        if d > max_km:
            continue
        out.append({
            "need_id": need.id, "report_id": report.id, "incident_label": dispatch.incident_label(report),
            "label": cfg["need_catalog"].get(need.category, {}).get("label", need.category),
            "skill": need.skill, "skill_match": need.skill.lower() in skills,
            "quota": need.quota, "accepted": dispatch.accepted_count(db, need.id), "status": need.status,
            "distance_km": round(d, 2), "address_text": report.address_text,
        })
    out.sort(key=lambda x: (not x["skill_match"], x["distance_km"]))
    return out
