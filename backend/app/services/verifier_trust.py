"""Verifier trust score -- independent of reporter trust (trust.py). Source
data: Sighting (a 'Ya' verification) cross-referenced against the settled
ground-truth verdict of the report it was made on (AccuracyFeedback.verdict,
majority vote across everyone who submitted post-resolution feedback).

Design doc: docs/superpowers/specs/2026-09-19-verifier-trust-design.md
"""
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db.models import AccuracyFeedback, Sighting

BASELINE = 50
CORRECT_DELTA = 2
WRONG_DELTA = -3  # asymmetric: confirming a hoax costs more than confirming real gains
MIN_EVALUATED_FOR_TIER = 3

TIER_LABELS = {
    "akun_baru": "Akun Baru",
    "rendah": "Rendah",
    "cukup": "Cukup",
    "baik": "Baik",
    "sangat_baik": "Sangat Baik",
}


def report_verdict(db: Session, report_id: str) -> str | None:
    """Majority vote across everyone who submitted accuracy feedback for this
    report. None means unsettled (no feedback yet) -- callers must treat this
    as "don't know", never as "valid by default"."""
    votes = list(db.scalars(select(AccuracyFeedback.verdict).where(AccuracyFeedback.report_id == report_id)))
    if not votes:
        return None
    hoax_votes = sum(1 for v in votes if v == "hoax")
    return "hoax" if hoax_votes * 2 > len(votes) else "valid"  # tie -> valid


def verifier_score(db: Session, user_id: str) -> tuple[int, int]:
    """Returns (score, evaluated_count). Computed at read time from raw rows --
    no stored running counter, matching trust.py's existing architecture."""
    sightings = db.scalars(select(Sighting).where(Sighting.user_id == user_id)).all()
    score = BASELINE
    evaluated = 0
    for s in sightings:
        verdict = report_verdict(db, s.report_id)
        if verdict is None:
            continue
        evaluated += 1
        score += CORRECT_DELTA if verdict == "valid" else WRONG_DELTA
    return max(0, min(100, score)), evaluated


def verifier_tier(db: Session, user_id: str) -> str:
    score, evaluated = verifier_score(db, user_id)
    if evaluated < MIN_EVALUATED_FOR_TIER:
        return "akun_baru"
    if score <= 25:
        return "rendah"
    if score <= 50:
        return "cukup"
    if score <= 75:
        return "baik"
    return "sangat_baik"


def verifier_payload(db: Session, user_id: str) -> dict:
    tier = verifier_tier(db, user_id)
    score, _ = verifier_score(db, user_id)
    return {"tier": tier, "label": TIER_LABELS[tier], "score": score}
