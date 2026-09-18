"""Reporting, extraction confirmation, status, map & nearby widget
(FR-2.x, FR-3.x, FR-4.x, FR-7.x, FR-8.x, FR-10.x)."""
from typing import Literal

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..core.app_config import Cfg
from ..core.security import mask_phone, normalize_phone
from ..db.models import (
    AccuracyFeedback,
    Assignment,
    NearbyNotice,
    Need,
    Offer,
    Participant,
    Report,
    ReportExtraction,
    Sighting,
    User,
    utcnow,
)
from ..db.session import get_db
from ..services import agencies, confirmation, dispatch, extraction, storage
from ..services import skills as skills_service
from ..services.geo import haversine_km
from ..services.trust import trust_payload
from .deps import current_user, engine_lock, iso

router = APIRouter(tags=["reports"])


# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------
class StructuredIn(BaseModel):
    """Direct structured form -- the reporter may skip free text (5.5 step 2)."""
    title: str = ""
    description: str = Field(default="", max_length=4000)


class ReportIn(BaseModel):
    description: str = Field(default="", max_length=4000)
    input_mode: Literal["text", "form"] = "text"
    structured: StructuredIn | None = None
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    address_text: str | None = None
    is_manual_location: bool = False
    contact_phone: str | None = None
    photo_urls: list[str] = []


class NeedIn(BaseModel):
    skill_id: int
    quota: int = Field(ge=1, le=50)


class ConfirmIn(BaseModel):
    fields: dict[str, str] = {}
    needs: list[NeedIn]
    incident_type: str | None = None


class VoteIn(BaseModel):
    done: bool


class AccuracyIn(BaseModel):
    matches: bool


class OfficialIn(BaseModel):
    status: Literal["unknown", "dihubungi", "di_lokasi"]


# ---------------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------------
def extraction_view(report: Report) -> list[dict]:
    return [{"field": e.field_name, "label": extraction.FIELD_LABELS.get(e.field_name, e.field_name),
             "value": e.value, "ai_value": e.ai_value, "evidence": e.evidence, "confidence": e.confidence,
             "corrected": e.corrected} for e in report.extractions]


def needs_view(db: Session, report: Report, cfg: Cfg) -> list[dict]:
    out = []
    for n in report.needs:
        contacted = db.scalar(select(func.count()).select_from(Offer)
                              .where(Offer.need_id == n.id, Offer.status == "pending")) or 0
        out.append({
            "id": n.id, "skill_id": n.skill_id, "skill_name": n.skill.name,
            "quota": n.quota, "accepted": dispatch.accepted_count(db, n.id), "status": n.status,
            "exhausted": n.exhausted, "contacted": contacted, "current_batch": n.current_batch,
        })
    return out


def volunteers_view(db: Session, report: Report) -> list[dict]:
    rows = db.execute(
        select(Assignment, User, Need).join(User, User.id == Assignment.volunteer_id)
        .join(Need, Need.id == Assignment.need_id)
        .where(Assignment.report_id == report.id, Assignment.status != "dilepas")
        .order_by(Assignment.accepted_at)
    ).all()
    return [{
        "assignment_id": a.id, "name": u.name, "role": a.role, "order_number": a.order_number,
        "skill": need.skill.name, "travel_status": a.travel_status, "status": a.status,
        "distance_km": round(haversine_km(u.lat, u.lng, report.lat, report.lng), 2) if u.lat is not None else None,
        "lat": u.lat, "lng": u.lng, "location_updated_at": iso(u.location_updated_at),
        "accepted_at": iso(a.accepted_at), "is_simulated": u.is_simulated,
    } for a, u, need in rows]


def report_view(db: Session, report: Report, viewer: User) -> dict:
    """Role-aware detail. The reporter and involved volunteers see everything
    they need; other users see only what the map needs (NFR-15)."""
    cfg = Cfg(db)
    is_reporter = report.reporter_id == viewer.id
    my_assignment = db.scalar(select(Assignment).where(Assignment.report_id == report.id,
                                                       Assignment.volunteer_id == viewer.id))
    my_offers = db.scalars(select(Offer).where(Offer.report_id == report.id, Offer.volunteer_id == viewer.id)
                           .order_by(Offer.rank)).all()
    involved = is_reporter or my_assignment is not None or bool(my_offers)
    needs = needs_view(db, report, cfg)
    sightings = db.scalar(select(func.count()).select_from(Sighting).where(Sighting.report_id == report.id)) or 0
    i_saw = db.scalar(select(Sighting).where(Sighting.report_id == report.id,
                                             Sighting.user_id == viewer.id)) is not None
    participant = db.scalar(select(Participant).where(Participant.report_id == report.id,
                                                      Participant.user_id == viewer.id))
    out = {
        "id": report.id,
        "status": report.status,
        "incident_type": report.incident_type,
        "incident_label": dispatch.incident_label(report),
        "raw_text": report.raw_text,
        "input_mode": report.input_mode,
        "address_text": report.address_text,
        "lat": report.lat, "lng": report.lng,
        "is_manual_location": report.is_manual_location,
        "received_at": iso(report.received_at),
        "confirmed_at": iso(report.confirmed_at),
        "resolved_at": iso(report.resolved_at),
        "resolved_by": report.resolved_by,
        "photo_urls": report.photo_urls or [],
        "reporter_trust": trust_payload(db, report.reporter_id, cfg),
        "is_reporter": is_reporter,
        "needs": needs,
        "needs_total": sum(n["quota"] for n in needs),
        "accepted_total": sum(n["accepted"] for n in needs),
        "contacted_total": sum(n["contacted"] for n in needs),  # FR-2.6
        "sightings": sightings,  # FR-2.7 / FR-8.4 (display only)
        "i_saw": i_saw,
        "official_status": report.official_status,
        "distance_km": round(haversine_km(viewer.lat, viewer.lng, report.lat, report.lng), 2)
        if viewer.lat is not None else None,
        "is_volunteer": viewer.volunteer is not None and viewer.volunteer.is_active,
        "my_assignment": None if my_assignment is None else {
            "id": my_assignment.id, "role": my_assignment.role, "order_number": my_assignment.order_number,
            "travel_status": my_assignment.travel_status, "status": my_assignment.status,
        },
        "my_offer": None if not my_offers else {
            "id": my_offers[0].id, "status": my_offers[0].status, "need_id": my_offers[0].need_id,
        },
        "can_vote": participant is not None and not participant.excluded and report.status == "active",
        "my_vote_done": participant is not None and participant.voted_done_at is not None,
        "prompt_pending": confirmation.pending_prompt(db, report, viewer.id),
    }
    if involved:
        out["contact_phone_masked"] = mask_phone(report.contact_phone)  # FR-9.4
        out["volunteers"] = volunteers_view(db, report)
        out["quorum"] = confirmation.quorum_state(db, report, cfg)
        out["agencies"] = agencies.suggest(db, report.incident_type, report.lat, report.lng)
    if is_reporter:
        out["extraction"] = extraction_view(report)
        out["extraction_source"] = report.extraction_source
        out["extraction_ms"] = report.extraction_ms
        out["extraction_note"] = report.extraction_note
    return out


def _get_report(db: Session, report_id: str) -> Report:
    report = db.get(Report, report_id)
    if report is None:
        raise HTTPException(404, "Laporan tidak ditemukan.")
    return report


def _raise(err: dispatch.DispatchError):
    raise HTTPException(err.status_code, err.message)


# ---------------------------------------------------------------------------
# Create -> extract -> confirm (FR-2.1, FR-3.x, FR-4.x)
# ---------------------------------------------------------------------------
@router.post("/uploads")
async def upload_photo(file: UploadFile = File(...), user: User = Depends(current_user)):
    if file.content_type not in storage.ALLOWED:
        raise HTTPException(415, "Format foto tidak didukung (JPG/PNG/WEBP).")
    data = await file.read()
    if len(data) > 8 * 1024 * 1024:
        raise HTTPException(413, "Ukuran foto maksimal 8 MB.")
    return {"url": storage.save_photo(data, file.content_type)}


@router.post("/reports")
async def create_report(body: ReportIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Stores the original text immediately (FR-2.5), then extracts. Extraction can
    never block the report: the LLM has a timeout and a rule-based fallback."""
    text = body.description.strip()
    if body.input_mode == "text" and len(text) < 5:
        raise HTTPException(422, "Ceritakan kejadiannya minimal satu kalimat, atau gunakan formulir.")
    report = Report(
        reporter_id=user.id, raw_text=text, input_mode=body.input_mode, lat=body.lat, lng=body.lng,
        address_text=body.address_text, is_manual_location=body.is_manual_location,
        contact_phone=normalize_phone(body.contact_phone) if body.contact_phone else user.phone,
        photo_urls=body.photo_urls, received_at=utcnow(),
    )
    db.add(report)
    db.commit()  # the raw report is safe before any AI call

    if body.input_mode == "form" and body.structured is not None:
        s = body.structured
        fields = {
            "title": {"value": s.title.strip() or extraction.UNKNOWN, "evidence": None,
                      "confidence": 1.0 if s.title.strip() else 0.0},
            "description": {"value": s.description.strip() or extraction.UNKNOWN, "evidence": None,
                            "confidence": 1.0 if s.description.strip() else 0.0},
        }
        source, elapsed, note = "form", 0, "Diisi langsung lewat formulir."
        incident_type = extraction._incident_type_from(s.description or s.title)
        proposed_needs = []
    else:
        available_skills = skills_service.list_skills(db)
        result = await extraction.extract(text, available_skills)
        fields = {
            "title": {"value": result.title, "evidence": None, "confidence": 1.0 if result.source == "llm" else 0.0},
            "description": {"value": result.description, "evidence": None,
                            "confidence": 1.0 if result.source == "llm" else 0.0},
        }
        source, elapsed, note = result.source, result.elapsed_ms, result.note
        incident_type = result.incident_type
        proposed_needs = result.needs

    report.incident_type = incident_type
    report.extraction_source, report.extraction_ms, report.extraction_note = source, elapsed, note
    for name in extraction.FIELDS:
        f = fields[name]
        db.add(ReportExtraction(report_id=report.id, field_name=name, ai_value=f["value"], value=f["value"],
                                evidence=f["evidence"], confidence=f["confidence"]))
    db.commit()
    db.refresh(report)
    return {
        "report": report_view(db, report, user),
        "proposed_needs": proposed_needs,
        "catalog": catalog_payload(db),
    }


def catalog_payload(db: Session) -> list[dict]:
    return [{"skill_id": s.id, "name": s.name} for s in skills_service.list_skills(db)]


@router.post("/reports/{report_id}/confirm")
def confirm_report(report_id: str, body: ConfirmIn, user: User = Depends(current_user),
                   db: Session = Depends(get_db)):
    """FR-3.4 / FR-3.5: only after this does need matching start."""
    report = _get_report(db, report_id)
    if report.reporter_id != user.id:
        raise HTTPException(403, "Hanya pelapor yang dapat mengonfirmasi laporan ini.")
    if report.status != "draft":
        raise HTTPException(409, "Laporan sudah dikonfirmasi.")
    valid_skill_ids = {s.id for s in skills_service.list_skills(db)}
    specs, seen = [], set()
    for n in body.needs:
        if n.skill_id not in valid_skill_ids:
            raise HTTPException(422, f"Skill tidak dikenal: {n.skill_id}")
        if n.skill_id in seen:
            continue
        seen.add(n.skill_id)
        specs.append({"skill_id": n.skill_id, "quota": n.quota})
    if not specs:
        raise HTTPException(422, "Pilih minimal satu kebutuhan.")
    for e in report.extractions:
        if e.field_name in body.fields:
            new_value = body.fields[e.field_name].strip() or extraction.UNKNOWN
            e.corrected = new_value != e.ai_value
            e.value = new_value
    if body.incident_type:
        report.incident_type = body.incident_type
    with engine_lock:
        dispatch.activate_report(db, report, specs)
        db.commit()
    return report_view(db, report, user)


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------
@router.get("/reports/mine")
def my_reports(user: User = Depends(current_user), db: Session = Depends(get_db)):
    reports = db.scalars(select(Report).where(Report.reporter_id == user.id, Report.status != "draft")
                         .order_by(Report.received_at.desc()).limit(50)).all()
    return [{
        "id": r.id, "status": r.status, "incident_label": dispatch.incident_label(r),
        "address_text": r.address_text, "received_at": iso(r.received_at), "raw_text": r.raw_text[:140],
        "needs_total": sum(n.quota for n in r.needs),
        "accepted_total": sum(dispatch.accepted_count(db, n.id) for n in r.needs),
        "needs": [{"label": n.skill.name, "status": n.status} for n in r.needs],
    } for r in reports]


def _marker(db: Session, r: Report, viewer: User, cfg: Cfg) -> dict:
    return {
        "id": r.id, "lat": r.lat, "lng": r.lng, "status": r.status,
        "incident_label": dispatch.incident_label(r), "raw_text": r.raw_text[:280],
        "address_text": r.address_text, "received_at": iso(r.received_at),
        "distance_km": round(haversine_km(viewer.lat, viewer.lng, r.lat, r.lng), 2) if viewer.lat is not None else None,
        "sightings": db.scalar(select(func.count()).select_from(Sighting).where(Sighting.report_id == r.id)) or 0,
        "needs_total": sum(n.quota for n in r.needs),
        "accepted_total": sum(dispatch.accepted_count(db, n.id) for n in r.needs),
        "is_mine": r.reporter_id == viewer.id,
    }


@router.get("/reports/active")
def active_reports(user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Map markers for every active incident (5.4)."""
    cfg = Cfg(db)
    reports = db.scalars(select(Report).where(Report.status == "active").order_by(Report.received_at.desc())).all()
    return [_marker(db, r, user, cfg) for r in reports]


@router.get("/reports/nearby")
def nearby_reports(lat: float | None = None, lng: float | None = None, radius_km: float | None = None,
                   user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Nearby widget (5.7): section 1 = reports inside my radius that notified me,
    section 2 = other active reports around me."""
    cfg = Cfg(db)
    if lat is not None and lng is not None:
        user.lat, user.lng, user.location_updated_at = lat, lng, utcnow()
    if radius_km is not None and 0 < radius_km <= 20:
        user.nearby_radius_km = radius_km
    db.commit()
    radius = user.nearby_radius_km
    general = float(cfg["general_nearby_radius_km"])
    notified_ids = set(db.scalars(select(NearbyNotice.report_id).where(NearbyNotice.user_id == user.id)))
    section_notified, section_general = [], []
    for r in db.scalars(select(Report).where(Report.status == "active").order_by(Report.received_at.desc())):
        if r.reporter_id == user.id:
            continue
        m = _marker(db, r, user, cfg)
        d = m["distance_km"]
        if r.id in notified_ids and (d is None or d <= radius):
            section_notified.append(m)
        elif d is None or d <= general:
            section_general.append(m)
    return {"radius_km": radius, "notified": section_notified, "general": section_general}


@router.get("/reports/{report_id}")
def get_report(report_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    report = _get_report(db, report_id)
    if report.status == "draft" and report.reporter_id != user.id:
        raise HTTPException(404, "Laporan tidak ditemukan.")
    return report_view(db, report, user)


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
@router.post("/reports/{report_id}/sightings")
def add_sighting(report_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """'Saya melihat kejadian ini' -- display only, does not affect trust (5.7)."""
    report = _get_report(db, report_id)
    if report.status != "active":
        raise HTTPException(409, "Laporan ini sudah tidak aktif.")
    if report.reporter_id == user.id:
        raise HTTPException(400, "Pelapor tidak perlu mengonfirmasi laporannya sendiri.")
    if db.scalar(select(Sighting).where(Sighting.report_id == report.id, Sighting.user_id == user.id)) is None:
        db.add(Sighting(report_id=report.id, user_id=user.id))
        db.commit()
    return report_view(db, report, user)


@router.post("/reports/{report_id}/participate")
def participate(report_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    report = _get_report(db, report_id)
    with engine_lock:
        try:
            assignment = dispatch.participate(db, report, user)
        except dispatch.DispatchError as err:
            db.rollback()
            _raise(err)
        db.commit()
    return {"assignment_id": assignment.id}


@router.post("/reports/{report_id}/vote")
def vote(report_id: str, body: VoteIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Answer to 'Apakah bencana ini sudah teratasi?' (5.11). done=false only keeps
    the voter active (not AFK)."""
    report = _get_report(db, report_id)
    with engine_lock:
        try:
            confirmation.vote(db, report, user, body.done)
        except dispatch.DispatchError as err:
            db.rollback()
            _raise(err)
        db.commit()
    return report_view(db, report, user)


@router.post("/reports/{report_id}/accuracy")
def accuracy(report_id: str, body: AccuracyIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """FR-7.3: after resolution, involved volunteers say whether the field matched."""
    report = _get_report(db, report_id)
    if report.status != "resolved":
        raise HTTPException(409, "Laporan belum selesai.")
    a = db.scalar(select(Assignment).where(Assignment.report_id == report.id, Assignment.volunteer_id == user.id,
                                           Assignment.status == "selesai"))
    if a is None:
        raise HTTPException(403, "Hanya relawan yang terlibat yang dapat menilai laporan ini.")
    if db.scalar(select(AccuracyFeedback).where(AccuracyFeedback.report_id == report.id,
                                                AccuracyFeedback.user_id == user.id)) is None:
        db.add(AccuracyFeedback(report_id=report.id, reporter_id=report.reporter_id, user_id=user.id,
                                matches=body.matches))
        db.commit()
    return {"ok": True}


@router.post("/reports/{report_id}/official-status")
def official_status(report_id: str, body: OfficialIn, user: User = Depends(current_user),
                    db: Session = Depends(get_db)):
    """FR-10.4: official handling is a separate manual confirmation, never implied
    by pressing Call."""
    report = _get_report(db, report_id)
    involved = report.reporter_id == user.id or db.scalar(
        select(Assignment).where(Assignment.report_id == report.id, Assignment.volunteer_id == user.id)) is not None
    if not involved:
        raise HTTPException(403, "Hanya pelapor atau relawan yang terlibat.")
    report.official_status = body.status
    report.official_status_updated_at = utcnow()
    db.commit()
    return report_view(db, report, user)


@router.post("/assignments/{assignment_id}/release")
def release(assignment_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Reporter releases a volunteer (4.11: volunteers have no self-cancel)."""
    a = db.get(Assignment, assignment_id)
    if a is None:
        raise HTTPException(404, "Penugasan tidak ditemukan.")
    report = _get_report(db, a.report_id)
    if report.reporter_id != user.id:
        raise HTTPException(403, "Hanya pelapor yang dapat melepas relawan.")
    if report.status != "active" or a.status != "aktif":
        raise HTTPException(409, "Relawan ini tidak dapat dilepas.")
    with engine_lock:
        dispatch.release_assignment(db, a)
        db.commit()
    return report_view(db, report, user)


@router.get("/agencies/suggest")
def suggest_agencies(report_id: str | None = None, lat: float | None = None, lng: float | None = None,
                     incident_type: str = "kebakaran", user: User = Depends(current_user),
                     db: Session = Depends(get_db)):
    """FR-10.1 / 10.3. Available while reporting too (floating button, 5.6)."""
    if report_id:
        r = _get_report(db, report_id)
        return agencies.suggest(db, r.incident_type, r.lat, r.lng)
    return agencies.suggest(db, incident_type, lat if lat is not None else user.lat,
                            lng if lng is not None else user.lng)


@router.get("/needs/catalog")
def needs_catalog(user: User = Depends(current_user), db: Session = Depends(get_db)):
    return catalog_payload(db)
