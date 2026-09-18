"""Design parameters of the MVP (context doc Section 4 + Open Items).

Every value here is seeded into the ``app_config`` table on first start and
read back from it at runtime, so the team can tune them without a code change
(NFR-13): ``PUT /config/{key}`` or edit the table in Supabase.
"""
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db.models import AppConfig

DEFAULTS: dict[str, object] = {
    # --- Matching (4.2 - 4.9) ---------------------------------------------
    "max_distance_km": 5.0,
    "score_weights": {"evidence": 0.30, "verified_experience": 0.10, "distance": 0.40,
                      "completion": 0.10, "similar_disaster": 0.10},
    "evidence_scores": {"self_declared": 0.70, "certified": 1.00},
    "experience_cap": 10,
    "near_tie_threshold": 0.02,
    "min_score_threshold": 0.0,  # Open Item #8: only the hard filters gate by default
    "max_candidates": 50,  # Open Item #9: "top X" cap

    # --- Batch alarm (4.10) ---------------------------------------------------
    # Open Item #14 resolved in favour of Section 4.10: batch 1 = Required Need.
    "alarm_seconds": 30,
    "response_window_seconds": 300,
    "escalate_on_all_reject": True,  # FR-5.10

    # --- Collective confirmation (4.13 / 5.11, Open Item #2) ---------------
    # "proportional" = T(N) table of Section 4.13; "simple" = 5.11 (3 people / 50%).
    "quorum_mode": "proportional",
    "min_confirm_sources": 2,  # FR-7.2: more than one source (capped at population)
    "confirm_prompt_interval_seconds": 120,
    "auto_resolve_hours": 24,  # FR-7.4

    # --- Trust (FR-9.x, Open Item #12) ---------------------------------------
    "trust_min_reports": 3,
    "trust_good_ratio": 0.7,

    # --- Nearby widget (5.7) ---------------------------------------------------
    "general_nearby_radius_km": 10.0,

    # --- Demo simulation --------------------------------------------------------
    "sim_auto_respond": True,
    "sim_accept_probability": 0.7,
    "sim_speed_mps": 25.0,  # simulated volunteers move fast so the demo is watchable
    "sim_vote_after_arrival_seconds": 60,
}


def get_config(db: Session, key: str):
    row = db.get(AppConfig, key)
    return row.value if row is not None else DEFAULTS[key]


class Cfg:
    """Per-request/per-tick view of the config table, loaded in one query.

    The table is small (~25 rows) and every request touches several different
    keys (matching weights, batch/quorum settings, ...); fetching them one at a
    time was ~10 extra round trips per report against a remote DB (~2s), so we
    read the whole table up front instead."""

    def __init__(self, db: Session):
        self._db = db
        self._cache: dict[str, object] = {row.key: row.value for row in db.scalars(select(AppConfig))}

    def __getitem__(self, key: str):
        if key not in self._cache:
            self._cache[key] = DEFAULTS[key]
        return self._cache[key]


def seed_config(db: Session) -> None:
    for key, value in DEFAULTS.items():
        if db.get(AppConfig, key) is None:
            db.add(AppConfig(key=key, value=value))
    db.commit()
