"""Config tuning, debugging and demo helpers."""
from fastapi import APIRouter, Body, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from ..app_config import DEFAULTS, Cfg, get_config
from ..db import get_db
from ..models import AppConfig, Need, Report, User
from ..services import dispatch, simulation
from .deps import current_user, engine_lock

router = APIRouter(tags=["admin & demo"])


class PointIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


@router.get("/config")
def list_config(db: Session = Depends(get_db)):
    return {key: get_config(db, key) for key in DEFAULTS}


@router.put("/config/{key}")
def set_config(key: str, value=Body(..., embed=True), user: User = Depends(current_user),
               db: Session = Depends(get_db)):
    """Tune a design parameter at runtime (NFR-13), e.g. {"value": 60} for alarm_seconds."""
    if key not in DEFAULTS:
        raise HTTPException(404, f"Unknown config key: {key}")
    row = db.get(AppConfig, key)
    if row is None:
        db.add(AppConfig(key=key, value=value))
    else:
        row.value = value
    db.commit()
    return {key: value}


@router.get("/needs/{need_id}/candidates")
def candidates(need_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Debug view of the hard-filtered, scored & ranked pool for a need."""
    need = db.get(Need, need_id)
    if need is None:
        raise HTTPException(404, "Need not found")
    report = db.get(Report, need.report_id)
    ranked = dispatch.rank_for_need(db, need, report, Cfg(db))
    names = {u.id: u.name for u in db.query(User).filter(User.id.in_([c.user_id for c in ranked]))}
    return [{"rank": i, "name": names.get(c.user_id), "score": c.score, "distance_km": c.distance_km,
             "competency": c.competency, "selection_count": c.selection_count, "components": c.components}
            for i, c in enumerate(ranked, start=1)]


@router.post("/demo/relocate-sims")
def relocate_sims(body: PointIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Move the simulated volunteers around a point (e.g. the presenter's phone)."""
    with engine_lock:
        moved = simulation.relocate(db, body.lat, body.lng)
    return {"moved": moved}
