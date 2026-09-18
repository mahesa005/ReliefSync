"""Reporter trust tier (FR-9.1 / FR-9.2). Source data is only the post-resolution
field-accuracy feedback (FR-7.3) -- 'saya melihat kejadian ini' never counts.

A resolved report counts as *accurate* when the majority of its feedback says the
field matched the report. Tier is never exposed as a raw number."""
from collections import defaultdict

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..core.app_config import Cfg
from ..db.models import AccuracyFeedback

TIER_LABELS = {
    "baru": "Akun baru",
    "rendah": "Riwayat akurasi rendah",
    "baik": "Riwayat baik",
}


def trust_tier(db: Session, reporter_id: str, cfg: Cfg | None = None) -> str:
    cfg = cfg or Cfg(db)
    rows = db.scalars(select(AccuracyFeedback).where(AccuracyFeedback.reporter_id == reporter_id)).all()
    per_report: dict[str, list[bool]] = defaultdict(list)
    for r in rows:
        per_report[r.report_id].append(r.matches)
    if len(per_report) < int(cfg["trust_min_reports"]):
        return "baru"
    accurate = sum(1 for votes in per_report.values() if sum(votes) * 2 >= len(votes))
    return "baik" if accurate / len(per_report) >= float(cfg["trust_good_ratio"]) else "rendah"


def trust_payload(db: Session, reporter_id: str, cfg: Cfg | None = None) -> dict:
    tier = trust_tier(db, reporter_id, cfg)
    return {"tier": tier, "label": TIER_LABELS[tier]}
