"""Volunteer priority & matching (context doc Section 4). Pure functions -- no DB --
so the algorithm is unit-testable and reusable from the dispatcher.

    Hard filter : Availability ON, SkillMatch = 1, Distance <= 5 km, not the reporter
    Priority    = 0.30 E + 0.10 VE + 0.40 D + 0.10 CH + 0.10 SD
    Fairness    : |ΔScore| <= 0.02 -> lower Selection Count first
    Tie-break   : Distance -> Competency -> Selection Count -> available_since -> id
"""
import math
from dataclasses import dataclass, field
from datetime import datetime

from .geo import haversine_km


@dataclass
class VolunteerInput:
    user_id: str
    lat: float | None
    lng: float | None
    is_active: bool
    # skill_id -> (evidence type, verified experience count)
    skills: dict[int, tuple[str, int]]
    completion_count: int = 0
    disaster_experience: dict[str, int] = field(default_factory=dict)
    selection_count: int = 0
    available_since: datetime | None = None


@dataclass
class Candidate:
    user_id: str
    distance_km: float
    score: float
    competency: float
    selection_count: int
    components: dict[str, float]
    available_since: datetime | None = None


def diminishing(x: int, cap: int = 10) -> float:
    """ln(1 + min(x, cap)) / ln(1 + cap)  -> [0, 1]"""
    x = max(0, int(x))
    return math.log(1 + min(x, cap)) / math.log(1 + cap)


def skill_matches(required: int, skills: dict[int, tuple[str, int]]) -> int | None:
    """Exact match only -- MVP has no skill similarity (4.2)."""
    return required if required in skills else None


def score_volunteer(v: VolunteerInput, required_skill: int, disaster_type: str,
                    lat: float, lng: float, cfg) -> Candidate | None:
    """Return a scored Candidate, or None if any hard filter fails."""
    if not v.is_active or v.lat is None or v.lng is None:
        return None
    matched_skill_id = skill_matches(required_skill, v.skills)
    if matched_skill_id is None:
        return None
    max_km = float(cfg["max_distance_km"])
    d_km = haversine_km(v.lat, v.lng, lat, lng)
    if d_km > max_km:
        return None

    cap = int(cfg["experience_cap"])
    evidence_type, ve_count = v.skills[matched_skill_id]
    e = float(cfg["evidence_scores"].get(evidence_type, cfg["evidence_scores"]["self_declared"]))
    ve = diminishing(ve_count, cap)
    d = max(0.0, 1 - d_km / max_km)
    ch = diminishing(v.completion_count, cap)
    sd = diminishing(v.disaster_experience.get(disaster_type, 0), cap)

    w = cfg["score_weights"]
    score = (w["evidence"] * e + w["verified_experience"] * ve + w["distance"] * d
             + w["completion"] * ch + w["similar_disaster"] * sd)
    competency = 0.60 * e + 0.40 * ve  # C = 0.60E + 0.40VE
    return Candidate(
        user_id=v.user_id,
        distance_km=round(d_km, 3),
        score=round(score, 6),
        competency=round(competency, 6),
        selection_count=v.selection_count,
        components={"E": e, "VE": round(ve, 4), "D": round(d, 4), "CH": round(ch, 4), "SD": round(sd, 4)},
        available_since=v.available_since,
    )


def _tie_key(c: Candidate):
    since = c.available_since.timestamp() if c.available_since else float("inf")
    return (-c.score, c.distance_km, -c.competency, c.selection_count, since, c.user_id)


def apply_fairness(ranked: list[Candidate], threshold: float) -> list[Candidate]:
    """Near-tie fairness (4.8): a candidate moves ahead of a neighbour only when their
    scores are within `threshold` and it has been selected fewer times. Each swap is
    checked pairwise, so fairness never beats a significant score difference."""
    out = list(ranked)
    for i in range(1, len(out)):
        j = i
        while j > 0:
            a, b = out[j - 1], out[j]
            if abs(a.score - b.score) <= threshold + 1e-12 and b.selection_count < a.selection_count:
                out[j - 1], out[j] = b, a
                j -= 1
            else:
                break
    return out


def rank_candidates(volunteers: list[VolunteerInput], required_skill: int, disaster_type: str,
                    lat: float, lng: float, cfg, exclude_user_ids: set[str] = frozenset()) -> list[Candidate]:
    scored = []
    for v in volunteers:
        if v.user_id in exclude_user_ids:  # FR-5.4: never the reporter
            continue
        c = score_volunteer(v, required_skill, disaster_type, lat, lng, cfg)
        if c is not None and c.score >= float(cfg["min_score_threshold"]):
            scored.append(c)
    scored.sort(key=_tie_key)
    ranked = apply_fairness(scored, float(cfg["near_tie_threshold"]))
    return ranked[: int(cfg["max_candidates"])]


def batch_size(batch_number: int, remaining_need: int, candidates_remaining: int) -> int:
    """Section 4.10: B1 = Required Need, B2 = Remaining Need,
    B(k+2) = min(Remaining Need * 2^k, candidates remaining), k = 1, 2, 3 ..."""
    remaining_need = max(1, remaining_need)
    if batch_number <= 2:
        size = remaining_need
    else:
        size = remaining_need * (2 ** (batch_number - 2))
    return max(0, min(size, candidates_remaining))
