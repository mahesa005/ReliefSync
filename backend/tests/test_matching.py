import math
from datetime import datetime

import pytest

from app.app_config import DEFAULTS
from app.services.geo import offset_point
from app.services.matching import (
    VolunteerInput,
    apply_fairness,
    batch_size,
    diminishing,
    rank_candidates,
    score_volunteer,
)

CFG = dict(DEFAULTS)
SITE = (-6.1470, 106.8055)


def vol(uid, km, skills=None, active=True, completion=0, fires=0, selection=0, bearing=0):
    lat, lng = offset_point(*SITE, km, bearing)
    return VolunteerInput(
        user_id=uid, lat=lat, lng=lng, is_active=active,
        skills=skills if skills is not None else {"Evakuasi": ("self_declared", 0)},
        completion_count=completion, disaster_experience={"kebakaran": fires}, selection_count=selection,
        available_since=datetime(2026, 1, 1),
    )


def test_diminishing_return_caps_at_10():
    assert diminishing(0) == 0
    assert diminishing(10) == pytest.approx(1.0)
    assert diminishing(50) == pytest.approx(1.0)
    assert diminishing(1) == pytest.approx(math.log(2) / math.log(11))


def test_priority_formula_matches_spec():
    v = vol("a", 1.0, skills={"Evakuasi": ("certified", 3)}, completion=2, fires=1)
    c = score_volunteer(v, "evakuasi", "kebakaran", *SITE, CFG)
    e, ve, d = 1.0, diminishing(3), 1 - c.distance_km / 5
    expected = 0.30 * e + 0.10 * ve + 0.40 * d + 0.10 * diminishing(2) + 0.10 * diminishing(1)
    assert c.score == pytest.approx(expected, abs=1e-5)
    assert c.competency == pytest.approx(0.6 * e + 0.4 * ve, abs=1e-5)
    assert c.distance_km == pytest.approx(1.0, abs=0.01)


@pytest.mark.parametrize("v", [
    vol("off", 1, active=False),                          # availability OFF
    vol("noskill", 1, skills={"Logistik": ("certified", 5)}),  # SkillMatch = 0
    vol("far", 5.2),                                      # distance > 5 km
])
def test_hard_filters(v):
    assert score_volunteer(v, "Evakuasi", "kebakaran", *SITE, CFG) is None


def test_reporter_is_excluded():
    ranked = rank_candidates([vol("reporter", 0.5), vol("other", 2)], "Evakuasi", "kebakaran", *SITE, CFG,
                             exclude_user_ids={"reporter"})
    assert [c.user_id for c in ranked] == ["other"]


def test_distance_dominates_ranking():
    ranked = rank_candidates([vol("far", 4), vol("near", 0.5), vol("mid", 2)], "Evakuasi", "kebakaran", *SITE, CFG)
    assert [c.user_id for c in ranked] == ["near", "mid", "far"]


def test_fairness_only_on_near_ties():
    # 0.01 km apart -> near-identical score: lower selection count goes first
    a = vol("a", 1.00, selection=5)
    b = vol("b", 1.02, selection=0, bearing=90)
    ranked = rank_candidates([a, b], "Evakuasi", "kebakaran", *SITE, CFG)
    assert [c.user_id for c in ranked] == ["b", "a"]
    # 1 km apart -> significant difference: fairness must not override
    c = vol("c", 1.0, selection=9)
    d = vol("d", 2.0, selection=0)
    ranked = rank_candidates([c, d], "Evakuasi", "kebakaran", *SITE, CFG)
    assert [x.user_id for x in ranked] == ["c", "d"]


def test_fairness_is_pairwise():
    from app.services.matching import Candidate
    cs = [Candidate("x", 1, 0.80, 0.7, 3, {}), Candidate("y", 1, 0.79, 0.7, 3, {}),
          Candidate("z", 1, 0.775, 0.7, 0, {})]
    # z may pass y (0.015) but not x (0.025)
    assert [c.user_id for c in apply_fairness(cs, 0.02)] == ["x", "z", "y"]


def test_exact_tie_breaks_on_distance_then_competency():
    from app.services.matching import _tie_key, Candidate
    cs = [Candidate("far", 2.0, 0.5, 0.9, 0, {}), Candidate("near", 1.0, 0.5, 0.1, 0, {}),
          Candidate("near_competent", 1.0, 0.5, 0.8, 0, {})]
    assert [c.user_id for c in sorted(cs, key=_tie_key)] == ["near_competent", "near", "far"]


def test_batch_sizes_follow_section_4_10():
    assert batch_size(1, 3, 100) == 3        # Batch 1 = Required Need
    assert batch_size(2, 2, 100) == 2        # Batch 2 = Remaining Need
    assert batch_size(3, 2, 100) == 4        # x2
    assert batch_size(4, 2, 100) == 8        # x4
    assert batch_size(5, 2, 5) == 5          # capped by candidates left
