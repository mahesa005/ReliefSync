# Event Verification & Verifier Trust Score Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a point-based verifier trust score, kept fully independent of reporter trust, by extending the existing post-resolution accuracy-feedback flow with one new ground-truth field and adding a read-time scoring service that mirrors `trust.py`'s existing architecture.

**Architecture:** `AccuracyFeedback` gains a `verdict` field ("valid"/"hoax") answered by the same volunteers who already answer `matches`, at the same post-resolution moment. A new `services/verifier_trust.py` computes each report's ground truth by majority vote (same pattern as `trust.py`'s reporter-accuracy vote), then computes any user's verifier score by walking their `Sighting` rows and crediting/penalizing each one against its report's settled verdict — entirely at read time, no stored running counter.

**Tech Stack:** Python 3.11+, FastAPI, SQLAlchemy 2.0 (schema via `Base.metadata.create_all()`, no manual migrations), pytest.

## Global Constraints

- No manual SQL migrations. Schema changes are SQLAlchemy model changes only; tables/columns on already-existing tables need a manual `ALTER TABLE` on any previously-deployed database (same caveat as `Report.content_valid` earlier) — `create_all()` never alters existing tables.
- Verifier trust and reporter trust are **independent** — no shared code path, no combined score, per the design spec's explicit non-goal. `services/verifier_trust.py` is a new, separate module from `services/trust.py`, not an extension of it.
- Scoring constants, exact values: `BASELINE = 50`, `CORRECT_DELTA = 2`, `WRONG_DELTA = -3`, clamped to `[0, 100]`. Tiers: Akun Baru (`evaluated_count < 3`), Rendah (0-25), Cukup (26-50), Baik (51-75), Sangat Baik (76-100). Ties in a report's verdict vote go to "valid".
- A report with no accuracy feedback submitted at all has an **unsettled** verdict (`None`) — verifiers who confirmed it are skipped, never guessed at as correct or wrong.
- "Tidak yakin" (not sure) on a verification prompt creates no `Sighting` row and has no scoring effect — this plan does not need to touch the `Sighting` model at all, only how it's *interpreted* for scoring.
- This plan is backend-only. The Flutter UI change (splitting the sighting tap into explicit "Ya"/"Tidak yakin" buttons, and adding the hoax/valid question to the resolution popup) is a follow-up, not covered here — same pattern as the earlier extraction-schema plan, which also scoped frontend work separately.
- The full test suite (`cd backend && .venv/Scripts/python.exe -m pytest -q`) must pass at the end of every task.
- No new pip dependencies.

---

### Task 1: Add `verdict` ground-truth field to `AccuracyFeedback`

**Files:**
- Modify: `backend/app/db/models.py`
- Modify: `backend/app/api/reports.py`
- Modify: `backend/tests/test_flow.py`

**Interfaces:**
- Produces: `AccuracyFeedback.verdict: str` (values `"valid"` or `"hoax"`, DB default `"valid"` for pre-existing rows only). `AccuracyIn.verdict: Literal["valid", "hoax"]` (required, no default, on the API input).

- [ ] **Step 1: Write the failing test**

In `backend/tests/test_flow.py`, the existing accuracy-flow assertion (around line 350) currently posts without `verdict`:
```python
    assert client.post(f"/reports/{rid}/accuracy", headers=vol_h, json={"matches": True}).status_code == 200
```
Change it to require `verdict` (this is the "failing test" step — it will fail until `AccuracyIn` actually requires and the endpoint actually stores this field):
```python
    r = client.post(f"/reports/{rid}/accuracy", headers=vol_h, json={"matches": True, "verdict": "valid"})
    assert r.status_code == 200, r.text
    fb = db.scalar(select(AccuracyFeedback).where(AccuracyFeedback.report_id == rid, AccuracyFeedback.user_id == vol_id))
    assert fb.verdict == "valid"
```
This needs `AccuracyFeedback` imported in `test_flow.py` — check the existing top-of-file import block; if `AccuracyFeedback` isn't already imported there (it's currently only imported inline inside `test_trust_tier_from_accuracy`), add it to the top-level `from app.db.models import (...)` block instead of leaving it as a scattered inline import, and remove the now-redundant inline `from app.db.models import AccuracyFeedback` inside `test_trust_tier_from_accuracy`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_flow.py::test_volunteer_api_accept_and_task -v`
Expected: FAIL — either a `KeyError`/`AttributeError` on `fb.verdict` (column doesn't exist yet) or the request itself still succeeds but the row has no such attribute to assert on.

- [ ] **Step 3: Add the column to `AccuracyFeedback`**

In `backend/app/db/models.py`, the current class:
```python
class AccuracyFeedback(Base):
    """Post-resolution 'did the field match the report?' (FR-7.3) -> trust score."""

    __tablename__ = "accuracy_feedback"
    __table_args__ = (UniqueConstraint("report_id", "user_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    reporter_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"))
    matches: Mapped[bool] = mapped_column(Boolean)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
```
becomes:
```python
class AccuracyFeedback(Base):
    """Post-resolution 'did the field match the report?' (FR-7.3) -> reporter trust,
    and 'was this event real or a hoax?' (verdict) -> independent verifier trust
    (see services/verifier_trust.py -- these two scores are never combined)."""

    __tablename__ = "accuracy_feedback"
    __table_args__ = (UniqueConstraint("report_id", "user_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    reporter_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"))
    matches: Mapped[bool] = mapped_column(Boolean)
    # "valid" | "hoax" -- default exists only for rows written before this column
    # existed on an already-deployed database; new submissions always provide it
    # explicitly via AccuracyIn (no default there).
    verdict: Mapped[str] = mapped_column(String(10), default="valid")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
```
(`String` is already imported in this file's top-level `from sqlalchemy import (...)` block, used by many other models — no new import needed.)

- [ ] **Step 4: Update `AccuracyIn` and the `accuracy` endpoint in `reports.py`**

Current:
```python
class AccuracyIn(BaseModel):
    matches: bool
```
becomes:
```python
class AccuracyIn(BaseModel):
    matches: bool
    verdict: Literal["valid", "hoax"]
```
(`Literal` is already imported at the top of `reports.py` via `from typing import Literal`.)

Current `accuracy()` endpoint body:
```python
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
```
becomes (one field added to the `AccuracyFeedback(...)` construction, docstring updated):
```python
@router.post("/reports/{report_id}/accuracy")
def accuracy(report_id: str, body: AccuracyIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """FR-7.3: after resolution, involved volunteers say whether the field matched
    (-> reporter trust) and whether the event was real or a hoax (-> verifier trust,
    for whoever confirmed a Sighting on this report -- see verifier_trust.py)."""
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
                                matches=body.matches, verdict=body.verdict))
        db.commit()
    return {"ok": True}
```

- [ ] **Step 5: Update the stale "never feeds trust" comments**

`Sighting`'s docstring in `backend/app/db/models.py` currently reads:
```python
class Sighting(Base):
    """'Saya melihat kejadian ini' -- display only, never feeds trust (5.7)."""
```
This is no longer accurate once Task 2 lands (a `Sighting` becomes an input to verifier scoring). Update it now so it doesn't linger stale in the meantime:
```python
class Sighting(Base):
    """'Saya melihat kejadian ini' (5.7). Feeds verifier trust once the report's
    outcome is known (see services/verifier_trust.py) -- never affects reporter
    trust, matching, or dispatch."""
```

Similarly, `add_sighting`'s docstring in `backend/app/api/reports.py`:
```python
def add_sighting(report_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """'Saya melihat kejadian ini' -- display only, does not affect trust (5.7)."""
```
becomes:
```python
def add_sighting(report_id: str, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """'Saya melihat kejadian ini' (5.7). Never affects this report's dispatch/matching,
    and never affects the reporter's own trust -- but does feed the confirming user's
    own verifier trust once the report resolves (see services/verifier_trust.py)."""
```

- [ ] **Step 6: Run the full test suite**

Run: `cd backend && .venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass, including the updated `test_volunteer_api_accept_and_task`.

- [ ] **Step 7: Commit**

```bash
git add backend/app/db/models.py backend/app/api/reports.py backend/tests/test_flow.py
git commit -m "feat: add verdict (valid/hoax) ground-truth field to accuracy feedback"
```

---

### Task 2: Verifier trust scoring service

**Files:**
- Create: `backend/app/services/verifier_trust.py`
- Create: `backend/tests/test_verifier_trust.py`

**Interfaces:**
- Consumes: `AccuracyFeedback.verdict` (Task 1), `Sighting` (existing model, unchanged).
- Produces: `report_verdict(db: Session, report_id: str) -> str | None`, `verifier_score(db: Session, user_id: str) -> tuple[int, int]` (returns `(score, evaluated_count)`), `verifier_tier(db: Session, user_id: str) -> str`, `verifier_payload(db: Session, user_id: str) -> dict` (returns `{"tier": ..., "label": ..., "score": ...}`), `TIER_LABELS: dict[str, str]`.

- [ ] **Step 1: Write the failing tests**

Create `backend/tests/test_verifier_trust.py`:
```python
"""Verifier trust score -- independent of reporter trust (design doc:
docs/superpowers/specs/2026-09-19-verifier-trust-design.md)."""
from app.db.models import AccuracyFeedback, Report, Sighting, User
from app.services.verifier_trust import (
    BASELINE,
    CORRECT_DELTA,
    WRONG_DELTA,
    report_verdict,
    verifier_payload,
    verifier_score,
    verifier_tier,
)


def _report(db, reporter_id, report_id="r1"):
    r = Report(id=report_id, reporter_id=reporter_id, raw_text="x", lat=0, lng=0)
    db.add(r)
    db.flush()
    return r


def _user(db, phone):
    u = User(name="U", phone=phone, password_hash="!")
    db.add(u)
    db.flush()
    return u


def test_report_verdict_is_none_with_no_feedback(db):
    reporter = _user(db, "081200000101")
    report = _report(db, reporter.id)
    db.commit()
    assert report_verdict(db, report.id) is None


def test_report_verdict_majority_vote_and_tie_goes_to_valid(db):
    reporter = _user(db, "081200000102")
    report = _report(db, reporter.id)
    v1, v2, v3 = (_user(db, f"08120000010{i}") for i in (3, 4, 5))
    db.add_all([
        AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=v1.id, matches=True, verdict="hoax"),
        AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=v2.id, matches=True, verdict="valid"),
    ])
    db.commit()
    assert report_verdict(db, report.id) == "valid"  # 1 hoax vs 1 valid -> tie -> valid

    db.add(AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=v3.id, matches=True, verdict="hoax"))
    db.commit()
    assert report_verdict(db, report.id) == "hoax"  # 2 hoax vs 1 valid -> hoax


def test_verifier_score_skips_unsettled_reports(db):
    reporter = _user(db, "081200000110")
    verifier = _user(db, "081200000111")
    report = _report(db, reporter.id, "r-unsettled")
    db.add(Sighting(report_id=report.id, user_id=verifier.id))
    db.commit()
    score, evaluated = verifier_score(db, verifier.id)
    assert (score, evaluated) == (BASELINE, 0)


def test_verifier_score_rewards_correct_and_penalizes_wrong(db):
    reporter = _user(db, "081200000120")
    verifier = _user(db, "081200000121")
    good_report = _report(db, reporter.id, "r-good")
    bad_report = _report(db, reporter.id, "r-bad")
    other = _user(db, "081200000122")
    db.add_all([
        Sighting(report_id=good_report.id, user_id=verifier.id),
        Sighting(report_id=bad_report.id, user_id=verifier.id),
        AccuracyFeedback(report_id=good_report.id, reporter_id=reporter.id, user_id=other.id,
                         matches=True, verdict="valid"),
        AccuracyFeedback(report_id=bad_report.id, reporter_id=reporter.id, user_id=other.id,
                         matches=True, verdict="hoax"),
    ])
    db.commit()
    score, evaluated = verifier_score(db, verifier.id)
    assert evaluated == 2
    assert score == BASELINE + CORRECT_DELTA + WRONG_DELTA


def test_verifier_score_clamps_to_0_100(db):
    reporter = _user(db, "081200000130")
    verifier = _user(db, "081200000131")
    other = _user(db, "081200000132")
    for i in range(30):  # far more than enough to blow past the clamp in either direction
        report = _report(db, reporter.id, f"r-clamp-{i}")
        db.add(Sighting(report_id=report.id, user_id=verifier.id))
        db.add(AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=other.id,
                                matches=True, verdict="hoax"))
    db.commit()
    score, evaluated = verifier_score(db, verifier.id)
    assert evaluated == 30
    assert score == 0  # clamped, not negative


def test_verifier_tier_gates_on_evaluated_count_then_score(db):
    reporter = _user(db, "081200000140")
    verifier = _user(db, "081200000141")
    other = _user(db, "081200000142")
    assert verifier_tier(db, verifier.id) == "akun_baru"  # zero evaluated

    for i in range(2):
        report = _report(db, reporter.id, f"r-gate-{i}")
        db.add(Sighting(report_id=report.id, user_id=verifier.id))
        db.add(AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=other.id,
                                matches=True, verdict="valid"))
    db.commit()
    assert verifier_tier(db, verifier.id) == "akun_baru"  # only 2 evaluated, gate is 3

    report = _report(db, reporter.id, "r-gate-3")
    db.add(Sighting(report_id=report.id, user_id=verifier.id))
    db.add(AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=other.id,
                            matches=True, verdict="valid"))
    db.commit()
    # 3 correct: score = 50 + 3*2 = 56 -> "baik" (51-75)
    assert verifier_tier(db, verifier.id) == "baik"


def test_verifier_payload_shape(db):
    reporter = _user(db, "081200000150")
    verifier = _user(db, "081200000151")
    db.commit()
    payload = verifier_payload(db, verifier.id)
    assert payload == {"tier": "akun_baru", "label": "Akun Baru", "score": BASELINE}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_verifier_trust.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'app.services.verifier_trust'`.

- [ ] **Step 3: Implement `services/verifier_trust.py`**

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_verifier_trust.py -v`
Expected: PASS (7 tests).

- [ ] **Step 5: Run the full test suite**

Run: `cd backend && .venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add backend/app/services/verifier_trust.py backend/tests/test_verifier_trust.py
git commit -m "feat: add independent verifier trust scoring service"
```

---

### Task 3: Expose verifier trust everywhere a reporter's trust already appears

Reporter trust (`trust_payload`) is currently shown in exactly four places: the user's own profile, and three places where *other* people see a reporter's trust tier (report detail, a volunteer's offer/alarm, a volunteer's active task). Verifier trust must appear alongside reporter trust in all four, not just on the user's own profile — these are two independent facets of the same person's credibility, and anywhere you're told "here's how trustworthy this reporter is," you should also be told "here's how trustworthy this same person has been as a verifier."

**Files:**
- Modify: `backend/app/api/me.py` (own profile)
- Modify: `backend/app/api/reports.py` (`report_view` — shown to anyone viewing a report)
- Modify: `backend/app/api/volunteer.py` (`offer_view` — shown on an offer/alarm; `task_view` — shown on an accepted task)
- Modify: `backend/tests/test_flow.py`

**Interfaces:**
- Consumes: `verifier_trust.verifier_payload(db, user_id)` (Task 2).
- Produces: a new `"reporter_verifier_trust"` key (shape `{"tier": str, "label": str, "score": int}`) placed directly alongside every existing `"reporter_trust"` key in `report_view`, `offer_view`, and `task_view`; and a `"verifier_trust"` key on `user_payload` (own profile — naming differs because there the subject is unambiguously "you," not "the reporter").

- [ ] **Step 1: Write the failing tests**

In `backend/tests/test_flow.py`, extend `test_register_login_and_otp` (it already fetches `/me` and asserts on `me["trust"]`):
```python
    me = client.get("/me", headers={"Authorization": f"Bearer {r.json()['token']}"}).json()
    assert me["phone_masked"] == "0812****2222"
    assert me["volunteer"] is None
    assert me["trust"]["label"] == "Akun baru"
```
becomes:
```python
    me = client.get("/me", headers={"Authorization": f"Bearer {r.json()['token']}"}).json()
    assert me["phone_masked"] == "0812****2222"
    assert me["volunteer"] is None
    assert me["trust"]["label"] == "Akun baru"
    assert me["verifier_trust"] == {"tier": "akun_baru", "label": "Akun Baru", "score": 50}
```

Also extend `test_volunteer_api_accept_and_task` (it already asserts `reqs[0]["reporter_trust"]["label"]`), right after that existing assertion:
```python
    assert reqs[0]["reporter_trust"]["label"] == "Akun baru"  # FR-9.3
```
add immediately after it:
```python
    assert reqs[0]["reporter_verifier_trust"] == {"tier": "akun_baru", "label": "Akun Baru", "score": 50}
```
and later in the same test, where `task` is fetched after accepting the offer, add one more assertion right after the existing task-role check:
```python
    task = client.post(f"/offers/{reqs[0]['offer_id']}/accept", headers=vol_h).json()
    assert task["role"] == "utama" and task["order_number"] == 1
```
becomes:
```python
    task = client.post(f"/offers/{reqs[0]['offer_id']}/accept", headers=vol_h).json()
    assert task["role"] == "utama" and task["order_number"] == 1
    assert task["reporter_verifier_trust"] == {"tier": "akun_baru", "label": "Akun Baru", "score": 50}
```

And extend `test_sighting_and_nearby_widget` (it already fetches a report view and checks fields on it), right after the existing sightings assertion:
```python
    view = client.post(f"/reports/{rid}/sightings", headers=other_h).json()
    assert view["sightings"] == 1 and view["i_saw"] is True
```
add:
```python
    assert view["reporter_verifier_trust"] == {"tier": "akun_baru", "label": "Akun Baru", "score": 50}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_flow.py::test_register_login_and_otp tests/test_flow.py::test_volunteer_api_accept_and_task tests/test_flow.py::test_sighting_and_nearby_widget -v`
Expected: FAIL — `KeyError` on the new keys in all three.

- [ ] **Step 3: Wire it into `me.py`'s `user_payload`**

Add the import:
```python
from ..services.trust import trust_payload
```
becomes:
```python
from ..services.trust import trust_payload
from ..services.verifier_trust import verifier_payload
```

In `user_payload`, current:
```python
def user_payload(db: Session, user: User) -> dict:
    v = user.volunteer
    return {
        "id": user.id,
        "name": user.name,
        "phone_masked": mask_phone(user.phone),  # FR-9.4 everywhere, even on own profile
        "notify_nearby": user.notify_nearby,
        "nearby_radius_km": user.nearby_radius_km,
        "lat": user.lat,
        "lng": user.lng,
        "trust": trust_payload(db, user.id),
        "created_at": iso(user.created_at),
```
becomes:
```python
def user_payload(db: Session, user: User) -> dict:
    v = user.volunteer
    return {
        "id": user.id,
        "name": user.name,
        "phone_masked": mask_phone(user.phone),  # FR-9.4 everywhere, even on own profile
        "notify_nearby": user.notify_nearby,
        "nearby_radius_km": user.nearby_radius_km,
        "lat": user.lat,
        "lng": user.lng,
        "trust": trust_payload(db, user.id),
        "verifier_trust": verifier_payload(db, user.id),
        "created_at": iso(user.created_at),
```
(the rest of the function/dict is unchanged).

- [ ] **Step 4: Wire it into `reports.py`'s `report_view`**

Add the import alongside the existing trust import:
```python
from ..services.trust import trust_payload
```
becomes:
```python
from ..services.trust import trust_payload
from ..services.verifier_trust import verifier_payload
```

Current:
```python
        "photo_urls": report.photo_urls or [],
        "reporter_trust": trust_payload(db, report.reporter_id, cfg),
        "is_reporter": is_reporter,
```
becomes:
```python
        "photo_urls": report.photo_urls or [],
        "reporter_trust": trust_payload(db, report.reporter_id, cfg),
        "reporter_verifier_trust": verifier_payload(db, report.reporter_id),
        "is_reporter": is_reporter,
```

- [ ] **Step 5: Wire it into `volunteer.py`'s `offer_view` and `task_view`**

Add the import alongside the existing trust import:
```python
from ..services.trust import trust_payload
```
becomes:
```python
from ..services.trust import trust_payload
from ..services.verifier_trust import verifier_payload
```

In `offer_view`, current:
```python
        "matched_skill": need.skill.name,
        "reporter_trust": trust_payload(db, report.reporter_id, cfg),  # FR-9.3
        "contact_phone_masked": mask_phone(report.contact_phone),
```
becomes:
```python
        "matched_skill": need.skill.name,
        "reporter_trust": trust_payload(db, report.reporter_id, cfg),  # FR-9.3
        "reporter_verifier_trust": verifier_payload(db, report.reporter_id),
        "contact_phone_masked": mask_phone(report.contact_phone),
```

In `task_view`, current:
```python
        "contact_phone_masked": mask_phone(report.contact_phone),
        "reporter_trust": trust_payload(db, report.reporter_id, cfg),
        "quorum": confirmation.quorum_state(db, report, cfg),
```
becomes:
```python
        "contact_phone_masked": mask_phone(report.contact_phone),
        "reporter_trust": trust_payload(db, report.reporter_id, cfg),
        "reporter_verifier_trust": verifier_payload(db, report.reporter_id),
        "quorum": confirmation.quorum_state(db, report, cfg),
```

- [ ] **Step 6: Run the full test suite**

Run: `cd backend && .venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add backend/app/api/me.py backend/app/api/reports.py backend/app/api/volunteer.py backend/tests/test_flow.py
git commit -m "feat: expose verifier trust wherever reporter trust already appears"
```

---

### Task 4: Docs and schema reference

**Files:**
- Modify: `backend/supabase/schema.sql` (regenerated, not hand-edited)
- Modify: `docs/superpowers/specs/2026-09-19-verifier-trust-design.md`
- Modify: `README.md`

**Interfaces:** none (documentation/reference-file task only).

- [ ] **Step 1: Regenerate `supabase/schema.sql`**

Run:
```bash
cd backend && .venv/Scripts/python.exe -m scripts.export_schema > supabase/schema.sql
```

- [ ] **Step 2: Verify the regenerated file contains the new column**

Run: `grep -n "verdict" backend/supabase/schema.sql`
Expected: shows a `verdict VARCHAR(10) NOT NULL` (or similar) column on the `accuracy_feedback` table definition.

- [ ] **Step 3: Add the deploy caveat to the design spec's rollout notes**

The design spec (`docs/superpowers/specs/2026-09-19-verifier-trust-design.md`) already has a "Migration / rollout note" section describing the `ALTER TABLE accuracy_feedback ADD COLUMN ...` caveat -- confirm it's still accurate (it was written before implementation; no change expected, just verify the column name/type it names matches what Task 1 actually built: `verdict VARCHAR(10) NOT NULL DEFAULT 'valid'`). If it drifted, correct it.

- [ ] **Step 4: Update README's tech-summary table**

Find the row describing trust/credibility (search for "trust" in `README.md`'s main tech table or Section 3 "Keputusan untuk Open Items" — if reporter trust is mentioned there, add a corresponding one-line mention of verifier trust as a separate, independent score). Match the existing table's style and language (Indonesian). If no existing row is a natural fit, add one to Section 3's table with an entry like: `| Verifier trust | Skor independen dari reporter trust, berbasis poin (+2 benar/-3 salah dari verdict valid/hoax pasca-resolusi), bukan rasio. Lihat docs/superpowers/specs/2026-09-19-verifier-trust-design.md. |`.

- [ ] **Step 5: Final full-suite run**

Run: `cd backend && .venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass — final verification for the whole plan.

- [ ] **Step 6: Commit**

```bash
git add backend/supabase/schema.sql README.md docs/superpowers/specs/2026-09-19-verifier-trust-design.md
git commit -m "docs: regenerate schema reference and document verifier trust in README"
```
