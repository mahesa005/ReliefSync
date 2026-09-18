# Skill-Based Report Extraction & Cross-Skill Dispatch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the regex-based 4-field extraction + 6-category need mapping with a Groq-driven pipeline against a real 12-skill catalog, and make dispatch credit one volunteer's multiple matching skills toward multiple needs on the same report.

**Architecture:** A new `Skill(id, name)` table (seeded from the "Skill Relawan — ReliefSync" reference doc) becomes the single source of truth for skill identity. `VolunteerSkill` and `Need` move from free-text skill strings to `skill_id` foreign keys. `extraction.py` makes one Groq call that outputs `title`, `description`, and a `needs: [{skill_id, quota}]` list, using the DB-fetched skill catalog to constrain valid outputs. `dispatch.py` gains a cross-skill credit step: when a volunteer accepts one need's alarm, their other skills are checked against the report's other open needs and credited via a new `Assignment.credited_skill_ids` column, without a separate alarm.

**Tech Stack:** Python 3.11+, FastAPI, SQLAlchemy 2.0 (declarative models, `Base.metadata.create_all()` for schema — no manual migrations), pytest, Groq's OpenAI-compatible chat completions API via `httpx` (no new SDK dependency).

## Global Constraints

- No manual SQL migrations. Every schema change is a SQLAlchemy model change; tables create themselves via `Base.metadata.create_all()` in `main.py`'s `init_db()`, in both SQLite (dev) and Supabase Postgres (prod) — this is the existing, established convention (`db/models.py`'s own docstring: "single source of truth").
- The skill catalog is exactly these 12 names, in this order, from the "Skill Relawan — ReliefSync" reference doc (IFest 2026, Tim STEICON) — no additional columns (no `kelompok`/definition fields) on `Skill`:
  `P3K`, `CPR / RJP`, `Penanganan perdarahan`, `Penggunaan AED`, `Pemasangan bidai`, `Penggunaan tandu`, `Teknik memindahkan korban`, `Mengemudi motor`, `Mengemudi mobil`, `Dukungan Psikologis Awal / PFA`, `Penggunaan APAR`, `Berenang`.
- `Assignment` keeps `UniqueConstraint("report_id", "volunteer_id")` unchanged (one row per volunteer per report). Cross-skill credit is recorded via a new `Assignment.credited_skill_ids: list[int]` (JSON) column on that same row, never via extra `Assignment` rows.
- `incident_type` classification is NOT part of the new LLM contract (it wasn't one of the 4 requested fields — title, description, skills, quota). The existing regex-based `_INCIDENT_PATTERNS`/`_incident_type_from` in `extraction.py` is kept and run directly against the raw report text, independent of the Groq call succeeding or failing.
- The full test suite (`cd backend && .venv/Scripts/python.exe -m pytest -q`, or `python -m pytest -q` if a venv is already active) must pass at the end of every task.
- No new pip dependencies — Groq is called via `httpx`, already in `requirements.txt`.

---

### Task 1: Skill catalog — model, seed, service

**Files:**
- Modify: `backend/app/db/models.py`
- Create: `backend/app/services/skills.py`
- Modify: `backend/app/main.py`
- Modify: `backend/tests/conftest.py`
- Create: `backend/tests/test_skills.py`

**Interfaces:**
- Produces: `Skill` model (`id: int`, `name: str`) in `app.db.models`. `seed_skills(db: Session) -> None` and `list_skills(db: Session) -> list[Skill]` in `app.services.skills`. `SEED_SKILLS: list[str]` (the 12 names) in `app.services.skills`.

- [ ] **Step 1: Write the failing test**

Create `backend/tests/test_skills.py`:
```python
from sqlalchemy import select

from app.db.models import Skill
from app.services.skills import SEED_SKILLS, list_skills, seed_skills


def test_seed_skills_creates_all_twelve(db):
    seed_skills(db)
    names = {s.name for s in db.scalars(select(Skill))}
    assert names == set(SEED_SKILLS)
    assert len(SEED_SKILLS) == 12


def test_seed_skills_is_idempotent(db):
    seed_skills(db)
    seed_skills(db)
    rows = list(db.scalars(select(Skill)))
    assert len(rows) == len(SEED_SKILLS)


def test_list_skills_returns_ordered_by_id():
    from app.db.session import SessionLocal
    with SessionLocal() as session:
        seed_skills(session)
        skills = list_skills(session)
        assert [s.name for s in skills] == SEED_SKILLS
        assert all(isinstance(s.id, int) for s in skills)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_skills.py -v`
Expected: FAIL with `ImportError: cannot import name 'Skill' from 'app.db.models'` (or `ModuleNotFoundError: No module named 'app.services.skills'`).

- [ ] **Step 3: Add the `Skill` model**

In `backend/app/db/models.py`, insert right after `new_id()` (before the "Accounts" section comment, so it's defined before anything references it):
```python
class Skill(Base):
    """Canonical skill catalog (Skill Relawan reference doc, IFest 2026 Tim STEICON).
    id + name only -- domain definitions/groupings live in the LLM prompt, not here."""

    __tablename__ = "skills"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(80), unique=True)
```

- [ ] **Step 4: Add `services/skills.py`**

Create `backend/app/services/skills.py`:
```python
"""Skill catalog: seed data and read access (Skill Relawan reference doc, IFest 2026 Tim STEICON)."""
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db.models import Skill

SEED_SKILLS: list[str] = [
    "P3K",
    "CPR / RJP",
    "Penanganan perdarahan",
    "Penggunaan AED",
    "Pemasangan bidai",
    "Penggunaan tandu",
    "Teknik memindahkan korban",
    "Mengemudi motor",
    "Mengemudi mobil",
    "Dukungan Psikologis Awal / PFA",
    "Penggunaan APAR",
    "Berenang",
]


def seed_skills(db: Session) -> None:
    if db.scalar(select(Skill).limit(1)) is not None:
        return
    for name in SEED_SKILLS:
        db.add(Skill(name=name))
    db.commit()


def list_skills(db: Session) -> list[Skill]:
    return list(db.scalars(select(Skill).order_by(Skill.id)))
```

- [ ] **Step 5: Wire seeding into `conftest.py`'s `db` fixture**

In `backend/tests/conftest.py`, add the import and call so every test that uses the `db` fixture has the catalog available:
```python
from app.app_config import seed_config  # noqa: E402
```
becomes (add one import line and one call, keeping everything else in the fixture unchanged):
```python
from app.core.app_config import seed_config  # noqa: E402
from app.services.skills import seed_skills  # noqa: E402
```
and in the `db` fixture function body, add `seed_skills(session)` on the line right after `seed_agencies(session)`:
```python
@pytest.fixture
def db():
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    session = SessionLocal()
    seed_config(session)
    seed_agencies(session)
    seed_skills(session)
    yield session
    session.close()
```

- [ ] **Step 6: Wire seeding into `main.py`'s `init_db()`**

In `backend/app/main.py`, add the import:
```python
from .services import agencies, confirmation, dispatch, simulation
```
becomes:
```python
from .services import agencies, confirmation, dispatch, simulation, skills
```
and in `init_db()`, add `skills.seed_skills(db)` alongside the other seed calls:
```python
with SessionLocal() as db:
    seed_config(db)
    agencies.seed_agencies(db)
    skills.seed_skills(db)
    if get_settings().seed_demo_data:
        simulation.seed_demo(db)
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_skills.py -v`
Expected: PASS (3 tests).

Run the full suite to confirm nothing else broke: `cd backend && .venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass (this task is purely additive — nothing existing references `Skill` yet).

- [ ] **Step 8: Commit**

```bash
git add backend/app/db/models.py backend/app/services/skills.py backend/app/main.py backend/tests/conftest.py backend/tests/test_skills.py
git commit -m "feat: add Skill catalog model, seed data, and service"
```

---

### Task 2: Migrate skill representation to `Skill`-catalog IDs

This is the big mechanical migration: every place that stored or matched skills as free-text strings (`VolunteerSkill.skill`, `Need.category`/`Need.skill`) moves to `skill_id: int` foreign keys. `needs.py` (the regex category mapper) is deleted. `proposed_needs` in the report-creation response becomes an empty list for now (manual selection only) — Task 4 restores AI-driven proposals on top of this.

**Files:**
- Modify: `backend/app/db/models.py` (`VolunteerSkill`, `Need`)
- Modify: `backend/app/core/app_config.py` (remove `need_catalog`)
- Delete: `backend/app/services/needs.py`
- Modify: `backend/app/services/matching.py`
- Modify: `backend/app/services/dispatch.py`
- Modify: `backend/app/api/reports.py`
- Modify: `backend/app/api/volunteer.py`
- Modify: `backend/app/api/me.py`
- Modify: `backend/app/api/auth.py`
- Modify: `backend/app/services/simulation.py`
- Modify: `backend/tests/test_matching.py`
- Modify: `backend/tests/test_flow.py`
- Modify: `backend/tests/test_rules.py`

**Interfaces:**
- Consumes: `Skill` from Task 1 (`app.db.models.Skill`), `list_skills(db)` from `app.services.skills`.
- Produces: `VolunteerSkill.skill_id: int`, `Need.skill_id: int` (both FK → `skills.id`), `matching.skill_matches(required: int, skills: dict[int, tuple[str, int]]) -> int | None`, `matching.VolunteerInput.skills: dict[int, tuple[str, int]]`. These are what Task 3 (cross-skill credit) and Task 4 (extraction rewrite) build on.

- [ ] **Step 1: Write the failing test for the new schema shape**

Add to `backend/tests/test_matching.py` (near the top, after the `vol()` helper — this test will fail first because `VolunteerInput.skills` values are still string-keyed in the fixtures below it; write this one first as the "spec" for the new shape):
```python
def test_skill_matches_is_id_based():
    from app.services.matching import skill_matches
    assert skill_matches(1, {1: ("self_declared", 0)}) == 1
    assert skill_matches(1, {2: ("self_declared", 0)}) is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_matching.py::test_skill_matches_is_id_based -v`
Expected: FAIL — `skill_matches(1, {1: (...)})` raises or returns wrong value, because `skill_matches` currently does case-insensitive string comparison (`required.strip().lower()` on an int raises `AttributeError: 'int' object has no attribute 'strip'`).

- [ ] **Step 3: Update `db/models.py`**

Replace the `VolunteerSkill` class:
```python
class VolunteerSkill(Base):
    __tablename__ = "volunteer_skills"
    __table_args__ = (UniqueConstraint("user_id", "skill_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("volunteer_profiles.user_id"), index=True)
    skill_id: Mapped[int] = mapped_column(ForeignKey("skills.id"), index=True)
    evidence: Mapped[str] = mapped_column(String(20), default="self_declared")  # or "certified"
    verified_experience: Mapped[int] = mapped_column(Integer, default=0)  # per skill (4.2)

    profile: Mapped[VolunteerProfile] = relationship(back_populates="skills")
    skill: Mapped[Skill] = relationship()
```

Replace the `Need` class:
```python
class Need(Base):
    __tablename__ = "needs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    skill_id: Mapped[int] = mapped_column(ForeignKey("skills.id"), index=True)  # Required Skill for SkillMatch
    quota: Mapped[int] = mapped_column(Integer)  # Required Need (FR-4.3)
    # belum_ada | sebagian | penuh | selesai (FR-8.1)
    status: Mapped[str] = mapped_column(String(20), default="belum_ada")
    exhausted: Mapped[bool] = mapped_column(Boolean, default=False)  # all candidates alarmed (FR-5.14)
    current_batch: Mapped[int] = mapped_column(Integer, default=0)
    batch_sent_at: Mapped[datetime | None] = mapped_column(DateTime)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    report: Mapped[Report] = relationship(back_populates="needs")
    skill: Mapped[Skill] = relationship()
```
(`category` and the string `skill` column are gone from both classes; note `Skill` must be defined above `VolunteerSkill`/`Need` in the file — it already is, from Task 1.)

- [ ] **Step 4: Remove `need_catalog` from `app_config.py`**

In `backend/app/core/app_config.py`, delete this whole block from `DEFAULTS`:
```python
    # --- Needs (FR-4.3, Open Item #3) ---------------------------------------
    "need_catalog": {
        "pemadaman_awal": {"label": "Pemadaman Api Awal", "skill": "Pemadaman Api", "quota": 3},
        "evakuasi": {"label": "Evakuasi Warga", "skill": "Evakuasi", "quota": 3},
        "medis": {"label": "Pertolongan Pertama", "skill": "P3K", "quota": 2},
        "logistik": {"label": "Logistik & Pengungsian", "skill": "Logistik", "quota": 2},
        "akses": {"label": "Pengaturan Akses & Lalu Lintas", "skill": "Pengaturan Lalu Lintas", "quota": 2},
        "psikososial": {"label": "Dukungan Psikososial", "skill": "Dukungan Psikososial", "quota": 1},
    },

```

- [ ] **Step 5: Delete `services/needs.py`**

```bash
git rm backend/app/services/needs.py
```

- [ ] **Step 6: Update `matching.py`**

Change the `VolunteerInput` skills type annotation:
```python
    # skill name -> (evidence type, verified experience count)
    skills: dict[str, tuple[str, int]]
```
becomes:
```python
    # skill_id -> (evidence type, verified experience count)
    skills: dict[int, tuple[str, int]]
```

Replace `skill_matches`:
```python
def skill_matches(required: str, skills: dict[str, tuple[str, int]]) -> str | None:
    """Exact (case-insensitive) match only -- MVP has no skill similarity (4.2)."""
    req = required.strip().lower()
    for name in skills:
        if name.strip().lower() == req:
            return name
    return None
```
becomes:
```python
def skill_matches(required: int, skills: dict[int, tuple[str, int]]) -> int | None:
    """Exact match only -- MVP has no skill similarity (4.2)."""
    return required if required in skills else None
```

In `score_volunteer`, update the signature and the one line that unpacks the match:
```python
def score_volunteer(v: VolunteerInput, required_skill: str, disaster_type: str,
```
becomes
```python
def score_volunteer(v: VolunteerInput, required_skill: int, disaster_type: str,
```
and
```python
    skill_name = skill_matches(required_skill, v.skills)
    if skill_name is None:
        return None
```
becomes
```python
    matched_skill_id = skill_matches(required_skill, v.skills)
    if matched_skill_id is None:
        return None
```
and further down:
```python
    evidence_type, ve_count = v.skills[skill_name]
```
becomes
```python
    evidence_type, ve_count = v.skills[matched_skill_id]
```

In `rank_candidates`, update the signature:
```python
def rank_candidates(volunteers: list[VolunteerInput], required_skill: str, disaster_type: str,
```
becomes
```python
def rank_candidates(volunteers: list[VolunteerInput], required_skill: int, disaster_type: str,
```

- [ ] **Step 7: Run the new matching test to verify it passes**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_matching.py::test_skill_matches_is_id_based -v`
Expected: PASS. (The rest of `test_matching.py` still fails at this point — fixed in Step 12.)

- [ ] **Step 8: Update `dispatch.py`**

In `volunteer_inputs`, change how the skills dict is built:
```python
            skills={s.skill: (s.evidence, s.verified_experience) for s in profile.skills},
```
becomes
```python
            skills={s.skill_id: (s.evidence, s.verified_experience) for s in profile.skills},
```

In `rank_for_need`, change what's passed as the required skill:
```python
    return matching.rank_candidates(
        volunteers if volunteers is not None else volunteer_inputs(db),
        need.skill, report.incident_type, report.lat, report.lng, cfg,
        exclude_user_ids={report.reporter_id},
    )
```
becomes
```python
    return matching.rank_candidates(
        volunteers if volunteers is not None else volunteer_inputs(db),
        need.skill_id, report.incident_type, report.lat, report.lng, cfg,
        exclude_user_ids={report.reporter_id},
    )
```

In `activate_report`, change `Need` construction:
```python
        need = Need(report_id=report.id, category=spec["category"], skill=spec["skill"],
                    quota=max(1, int(spec["quota"])), created_at=now)
```
becomes
```python
        need = Need(report_id=report.id, skill_id=spec["skill_id"],
                    quota=max(1, int(spec["quota"])), created_at=now)
```

In `_send_offer_notification`, replace the catalog/category lookup with the skill relationship:
```python
def _send_offer_notification(db: Session, offer: Offer, need: Need, report: Report, cfg: Cfg, user: User,
                             alarm: bool, trust: dict) -> None:
    catalog = cfg["need_catalog"]
    need_label = catalog.get(need.category, {}).get("label", need.category)
    title = ("🚨 ALARM: " if alarm else "") + f"{incident_label(report)} {offer.distance_km:.1f} km dari Anda"
    body = f"Dibutuhkan: {need_label} (skill {need.skill}). Pelapor: {trust['label']}."
    notify(db, user, "alarm" if alarm else "standard", title, body, {
        "report_id": report.id, "need_id": need.id, "offer_id": offer.id,
        "distance_km": offer.distance_km, "skill": need.skill, "need_label": need_label,
        "trust_tier": trust["tier"], "trust_label": trust["label"],
        "alarm_seconds": int(cfg["alarm_seconds"]) if alarm else 0,
    })
```
becomes
```python
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
```

In `accept_offer`, the notify call at the end:
```python
    notify(db, reporter, "info", f"{volunteer.name} menuju lokasi",
           f"Relawan ke-{order} untuk {need.skill} ({'Bantuan Utama' if role == 'utama' else 'Bantuan Tambahan'}).",
           {"report_id": report.id})
```
becomes
```python
    notify(db, reporter, "info", f"{volunteer.name} menuju lokasi",
           f"Relawan ke-{order} untuk {need.skill.name} "
           f"({'Bantuan Utama' if role == 'utama' else 'Bantuan Tambahan'}).",
           {"report_id": report.id})
```

In `participate`, change the skill-preference sort:
```python
    skills = {s.skill.lower() for s in user.volunteer.skills}
    needs = [n for n in report.needs if n.status != "selesai"]
    if not needs:
        raise DispatchError("Laporan ini tidak memiliki kebutuhan terbuka.")
    needs.sort(key=lambda n: (n.skill.lower() not in skills, -remaining_need(db, n)))
```
becomes
```python
    skills = {s.skill_id for s in user.volunteer.skills}
    needs = [n for n in report.needs if n.status != "selesai"]
    if not needs:
        raise DispatchError("Laporan ini tidak memiliki kebutuhan terbuka.")
    needs.sort(key=lambda n: (n.skill_id not in skills, -remaining_need(db, n)))
```

- [ ] **Step 9: Update `api/reports.py`**

Remove the now-dead import:
```python
from ..services.needs import map_needs
```
(delete this line entirely).

Add an import for the skills service, next to the existing services import:
```python
from ..services import agencies, confirmation, dispatch, extraction, storage
```
becomes
```python
from ..services import agencies, confirmation, dispatch, extraction, storage
from ..services import skills as skills_service
```

Replace `NeedIn`:
```python
class NeedIn(BaseModel):
    category: str
    quota: int = Field(ge=1, le=50)
```
becomes
```python
class NeedIn(BaseModel):
    skill_id: int
    quota: int = Field(ge=1, le=50)
```

Delete `_need_label` entirely:
```python
def _need_label(cfg: Cfg, category: str) -> str:
    return cfg["need_catalog"].get(category, {}).get("label", category)
```

Replace `needs_view`:
```python
def needs_view(db: Session, report: Report, cfg: Cfg) -> list[dict]:
    out = []
    for n in report.needs:
        contacted = db.scalar(select(func.count()).select_from(Offer)
                              .where(Offer.need_id == n.id, Offer.status == "pending")) or 0
        out.append({
            "id": n.id, "category": n.category, "label": _need_label(cfg, n.category), "skill": n.skill,
            "quota": n.quota, "accepted": dispatch.accepted_count(db, n.id), "status": n.status,
            "exhausted": n.exhausted, "contacted": contacted, "current_batch": n.current_batch,
        })
    return out
```
becomes
```python
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
```
(`cfg` parameter is now unused in `needs_view` — keep the parameter for now since `report_view` passes it positionally and other call sites may still expect the signature; do not change the call site.)

In `volunteers_view`, update the field read from `Need`:
```python
    return [{
        "assignment_id": a.id, "name": u.name, "role": a.role, "order_number": a.order_number,
        "skill": need.skill, "travel_status": a.travel_status, "status": a.status,
```
becomes
```python
    return [{
        "assignment_id": a.id, "name": u.name, "role": a.role, "order_number": a.order_number,
        "skill": need.skill.name, "travel_status": a.travel_status, "status": a.status,
```

In `create_report`, remove the `map_needs`-based proposal and the now-dead `text_for_rules` variable. Replace:
```python
    if body.input_mode == "form" and body.structured is not None:
        s = body.structured.model_dump()
        fields = {k: {"value": (v.strip() or extraction.UNKNOWN), "evidence": None,
                      "confidence": 1.0 if v.strip() else 0.0} for k, v in s.items()}
        source, elapsed, note = "form", 0, "Diisi langsung lewat formulir."
        incident_type = extraction._incident_type_from(s["jenis_kejadian"])
        text_for_rules = " ".join(s.values())
    else:
        result = await extraction.extract(text)
        fields, source, elapsed, note = result.fields, result.source, result.elapsed_ms, result.note
        incident_type = result.incident_type
        text_for_rules = f"{text} {fields['kebutuhan_dinyatakan']['value']} {fields['kondisi_akses']['value']}"

    report.incident_type = incident_type
    report.extraction_source, report.extraction_ms, report.extraction_note = source, elapsed, note
    for name in extraction.FIELDS:
        f = fields[name]
        db.add(ReportExtraction(report_id=report.id, field_name=name, ai_value=f["value"], value=f["value"],
                                evidence=f["evidence"], confidence=f["confidence"]))
    db.commit()
    db.refresh(report)
    cfg = Cfg(db)
    return {
        "report": report_view(db, report, user),
        "proposed_needs": map_needs(text_for_rules, incident_type, cfg["need_catalog"]),  # FR-4.1
        "catalog": catalog_payload(cfg),
    }


def catalog_payload(cfg: Cfg) -> list[dict]:
    return [{"category": k, "label": v["label"], "skill": v["skill"], "quota": v["quota"]}
            for k, v in cfg["need_catalog"].items()]
```
with (interim: still using the OLD 4-field extraction — Task 4 replaces this block again):
```python
    if body.input_mode == "form" and body.structured is not None:
        s = body.structured.model_dump()
        fields = {k: {"value": (v.strip() or extraction.UNKNOWN), "evidence": None,
                      "confidence": 1.0 if v.strip() else 0.0} for k, v in s.items()}
        source, elapsed, note = "form", 0, "Diisi langsung lewat formulir."
        incident_type = extraction._incident_type_from(s["jenis_kejadian"])
    else:
        result = await extraction.extract(text)
        fields, source, elapsed, note = result.fields, result.source, result.elapsed_ms, result.note
        incident_type = result.incident_type

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
        "proposed_needs": [],  # manual selection only until Task 4 wires the new extraction contract
        "catalog": catalog_payload(db),
    }


def catalog_payload(db: Session) -> list[dict]:
    return [{"skill_id": s.id, "name": s.name} for s in skills_service.list_skills(db)]
```

Replace `confirm_report`'s catalog validation:
```python
    cfg = Cfg(db)
    catalog = cfg["need_catalog"]
    specs, seen = [], set()
    for n in body.needs:
        if n.category not in catalog:
            raise HTTPException(422, f"Kategori kebutuhan tidak dikenal: {n.category}")
        if n.category in seen:
            continue
        seen.add(n.category)
        specs.append({"category": n.category, "skill": catalog[n.category]["skill"], "quota": n.quota})
```
becomes
```python
    valid_skill_ids = {s.id for s in skills_service.list_skills(db)}
    specs, seen = [], set()
    for n in body.needs:
        if n.skill_id not in valid_skill_ids:
            raise HTTPException(422, f"Skill tidak dikenal: {n.skill_id}")
        if n.skill_id in seen:
            continue
        seen.add(n.skill_id)
        specs.append({"skill_id": n.skill_id, "quota": n.quota})
```
(the `cfg = Cfg(db)` line is removed here since `confirm_report` no longer needs config for validation; check the rest of the function still uses `cfg` — it doesn't, so this is safe to delete.)

Replace `my_reports`'s needs summary:
```python
    reports = db.scalars(select(Report).where(Report.reporter_id == user.id, Report.status != "draft")
                         .order_by(Report.received_at.desc()).limit(50)).all()
    cfg = Cfg(db)
    return [{
        "id": r.id, "status": r.status, "incident_label": dispatch.incident_label(r),
        "address_text": r.address_text, "received_at": iso(r.received_at), "raw_text": r.raw_text[:140],
        "needs_total": sum(n.quota for n in r.needs),
        "accepted_total": sum(dispatch.accepted_count(db, n.id) for n in r.needs),
        "needs": [{"label": _need_label(cfg, n.category), "status": n.status} for n in r.needs],
    } for r in reports]
```
becomes
```python
    reports = db.scalars(select(Report).where(Report.reporter_id == user.id, Report.status != "draft")
                         .order_by(Report.received_at.desc()).limit(50)).all()
    return [{
        "id": r.id, "status": r.status, "incident_label": dispatch.incident_label(r),
        "address_text": r.address_text, "received_at": iso(r.received_at), "raw_text": r.raw_text[:140],
        "needs_total": sum(n.quota for n in r.needs),
        "accepted_total": sum(dispatch.accepted_count(db, n.id) for n in r.needs),
        "needs": [{"label": n.skill.name, "status": n.status} for n in r.needs],
    } for r in reports]
```

Update the `/needs/catalog` route:
```python
@router.get("/needs/catalog")
def needs_catalog(user: User = Depends(current_user), db: Session = Depends(get_db)):
    return catalog_payload(Cfg(db))
```
becomes
```python
@router.get("/needs/catalog")
def needs_catalog(user: User = Depends(current_user), db: Session = Depends(get_db)):
    return catalog_payload(db)
```

- [ ] **Step 10: Update `api/volunteer.py`**

In `offer_view`:
```python
        "need": {"id": need.id, "label": cfg["need_catalog"].get(need.category, {}).get("label", need.category),
                 "skill": need.skill, "quota": need.quota, "accepted": dispatch.accepted_count(db, need.id),
                 "status": need.status},
        "matched_skill": need.skill,
```
becomes
```python
        "need": {"id": need.id, "label": need.skill.name, "skill": need.skill.name, "skill_id": need.skill_id,
                 "quota": need.quota, "accepted": dispatch.accepted_count(db, need.id), "status": need.status},
        "matched_skill": need.skill.name,
```

In `task_view`:
```python
        "skill": need.skill,
        "need_label": cfg["need_catalog"].get(need.category, {}).get("label", need.category),
```
becomes
```python
        "skill": need.skill.name,
        "skill_id": need.skill_id,
        "need_label": need.skill.name,
```

In `open_needs`:
```python
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
```
becomes
```python
    skills = {s.skill_id for s in user.volunteer.skills}
    for need, report in rows:
        if report.reporter_id == user.id:
            continue
        d = haversine_km(user.lat, user.lng, report.lat, report.lng)
        if d > max_km:
            continue
        out.append({
            "need_id": need.id, "report_id": report.id, "incident_label": dispatch.incident_label(report),
            "label": need.skill.name, "skill": need.skill.name, "skill_id": need.skill_id,
            "skill_match": need.skill_id in skills,
            "quota": need.quota, "accepted": dispatch.accepted_count(db, need.id), "status": need.status,
            "distance_km": round(d, 2), "address_text": report.address_text,
        })
```

- [ ] **Step 11: Update `api/me.py`**

Add `Skill` to the models import:
```python
from ..db.models import (
    AccuracyFeedback,
    Assignment,
    Need,
    Notification,
    Participant,
    Report,
    User,
    VolunteerProfile,
    VolunteerSkill,
    utcnow,
)
```
becomes
```python
from ..db.models import (
    AccuracyFeedback,
    Assignment,
    Need,
    Notification,
    Participant,
    Report,
    Skill,
    User,
    VolunteerProfile,
    VolunteerSkill,
    utcnow,
)
```

Replace `SkillIn`:
```python
class SkillIn(BaseModel):
    skill: str = Field(min_length=1, max_length=60)
    evidence: Literal["self_declared", "certified"] = "self_declared"
```
becomes
```python
class SkillIn(BaseModel):
    skill_id: int
    evidence: Literal["self_declared", "certified"] = "self_declared"
```

In `volunteer_stats`, key the per-skill counter by name (for display):
```python
    per_skill: dict[str, int] = {}
    finished = not_afk = 0
    for a, need in rows:
        per_skill[need.skill] = per_skill.get(need.skill, 0) + 1
```
becomes
```python
    per_skill: dict[str, int] = {}
    finished = not_afk = 0
    for a, need in rows:
        per_skill[need.skill.name] = per_skill.get(need.skill.name, 0) + 1
```

In `user_payload`, include `skill_id` and resolve the name:
```python
            "skills": [{"skill": s.skill, "evidence": s.evidence, "verified_experience": s.verified_experience}
                       for s in v.skills],
```
becomes
```python
            "skills": [{"skill_id": s.skill_id, "skill": s.skill.name, "evidence": s.evidence,
                       "verified_experience": s.verified_experience} for s in v.skills],
```

Replace `upsert_volunteer`:
```python
@router.post("/volunteer")
def upsert_volunteer(body: VolunteerIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Activate the volunteer layer or replace its skill list (FR-1.3 / FR-1.4).
    Experience already earned on a skill is kept when the skill stays."""
    wanted = {s.skill.strip(): s for s in body.skills if s.skill.strip()}
    if not wanted:
        raise HTTPException(422, "Tambahkan minimal satu kemampuan.")
    profile = user.volunteer
    if profile is None:
        profile = VolunteerProfile(user_id=user.id, is_active=body.is_active)
        db.add(profile)
        db.flush()
        db.refresh(user)
    existing = {s.skill.lower(): s for s in profile.skills}
    keep = []
    for name, s in wanted.items():
        row = existing.get(name.lower())
        if row is None:
            row = VolunteerSkill(user_id=user.id, skill=name, evidence=s.evidence)
        else:
            row.evidence = s.evidence
        keep.append(row)
    profile.skills = keep
    if body.is_active and not profile.is_active:
        profile.available_since = utcnow()
    profile.is_active = body.is_active
    db.commit()
    db.refresh(user)
    return user_payload(db, user)
```
becomes
```python
@router.post("/volunteer")
def upsert_volunteer(body: VolunteerIn, user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Activate the volunteer layer or replace its skill list (FR-1.3 / FR-1.4).
    Experience already earned on a skill is kept when the skill stays."""
    wanted = {s.skill_id: s for s in body.skills}
    if not wanted:
        raise HTTPException(422, "Tambahkan minimal satu kemampuan.")
    valid_skill_ids = {row.id for row in db.scalars(select(Skill))}
    unknown = set(wanted) - valid_skill_ids
    if unknown:
        raise HTTPException(422, f"Skill tidak dikenal: {sorted(unknown)}")
    profile = user.volunteer
    if profile is None:
        profile = VolunteerProfile(user_id=user.id, is_active=body.is_active)
        db.add(profile)
        db.flush()
        db.refresh(user)
    existing = {s.skill_id: s for s in profile.skills}
    keep = []
    for skill_id, s in wanted.items():
        row = existing.get(skill_id)
        if row is None:
            row = VolunteerSkill(user_id=user.id, skill_id=skill_id, evidence=s.evidence)
        else:
            row.evidence = s.evidence
        keep.append(row)
    profile.skills = keep
    if body.is_active and not profile.is_active:
        profile.available_since = utcnow()
    profile.is_active = body.is_active
    db.commit()
    db.refresh(user)
    return user_payload(db, user)
```

- [ ] **Step 12: Update `api/auth.py`**

Replace the volunteer-skill creation loop in `register`:
```python
    if body.become_volunteer and user.volunteer is None:
        db.add(VolunteerProfile(user_id=user.id, is_active=True))
        for s in {s.skill.strip(): s for s in body.skills if s.skill.strip()}.values():
            db.add(VolunteerSkill(user_id=user.id, skill=s.skill.strip(), evidence=s.evidence))
```
becomes
```python
    if body.become_volunteer and user.volunteer is None:
        db.add(VolunteerProfile(user_id=user.id, is_active=True))
        for s in {s.skill_id: s for s in body.skills}.values():
            db.add(VolunteerSkill(user_id=user.id, skill_id=s.skill_id, evidence=s.evidence))
```

- [ ] **Step 13: Update `services/simulation.py`**

Add `Skill` to the models import:
```python
from ..db.models import (
    AccuracyFeedback,
    Assignment,
    Offer,
    Participant,
    Report,
    User,
    VolunteerProfile,
    VolunteerSkill,
    utcnow,
)
```
becomes
```python
from ..db.models import (
    AccuracyFeedback,
    Assignment,
    Offer,
    Participant,
    Report,
    Skill,
    User,
    VolunteerProfile,
    VolunteerSkill,
    utcnow,
)
```

Delete the old `SKILLS` constant:
```python
SKILLS = ["Pemadaman Api", "Evakuasi", "P3K", "Logistik", "Pengaturan Lalu Lintas", "Dukungan Psikososial"]
```

Replace the `DEMO_ACCOUNTS` skill tuples (name/evidence/experience) with plain skill names from the new catalog:
```python
DEMO_ACCOUNTS = [
    # phone, name, volunteer skills (None = reporter only)
    ("081200000001", "Demo Pelapor", None),
    ("081200000002", "Demo Relawan", [("Evakuasi", "certified", 2), ("P3K", "self_declared", 1),
                                      ("Pemadaman Api", "self_declared", 0)]),
]
```
becomes
```python
DEMO_ACCOUNTS = [
    # phone, name, volunteer skill names (None = reporter only) -- resolved to skill_id in seed_demo
    ("081200000001", "Demo Pelapor", None),
    ("081200000002", "Demo Relawan", ["Teknik memindahkan korban", "P3K", "Penggunaan APAR"]),
]
```

Replace `seed_demo`:
```python
def seed_demo(db: Session) -> None:
    if db.scalar(select(User).where(User.is_simulated.is_(True)).limit(1)) is not None:
        return
    rng = random.Random(2026)
    now = utcnow()
    for i, name in enumerate(SIM_NAMES):
        phone = f"0899{i:08d}"
        user = User(name=name, phone=phone, password_hash="!", phone_verified=True, is_simulated=True,
                    notify_nearby=False)
        db.add(user)
        db.flush()
        dist, bearing = _sim_offset(user.id)
        user.lat, user.lng = offset_point(*DEMO_CENTER, dist, bearing)
        user.location_updated_at = now
        profile = VolunteerProfile(
            user_id=user.id, is_active=rng.random() > 0.1,
            available_since=now - timedelta(minutes=rng.randint(1, 600)),
            completion_count=rng.choice([0, 0, 1, 2, 3, 5, 8]),
            selection_count=rng.randint(0, 6),
            disaster_experience={"kebakaran": rng.choice([0, 0, 1, 2, 4])},
        )
        db.add(profile)
        for skill in rng.sample(SKILLS, rng.randint(1, 3)):
            db.add(VolunteerSkill(user_id=user.id, skill=skill,
                                  evidence="certified" if rng.random() < 0.35 else "self_declared",
                                  verified_experience=rng.choice([0, 0, 1, 2, 3, 6])))

    for phone, name, skills in DEMO_ACCOUNTS:
        if db.scalar(select(User).where(User.phone == phone)) is not None:
            continue
        lat, lng = offset_point(*DEMO_CENTER, 0.8, 45 if skills else 200)
        user = User(name=name, phone=phone, password_hash=hash_password(DEMO_PASSWORD), phone_verified=True,
                    lat=lat, lng=lng, location_updated_at=now)
        db.add(user)
        db.flush()
        if skills:
            db.add(VolunteerProfile(user_id=user.id, is_active=True, available_since=now))
            for skill, evidence, ve in skills:
                db.add(VolunteerSkill(user_id=user.id, skill=skill, evidence=evidence, verified_experience=ve))
    db.commit()
```
becomes
```python
def seed_demo(db: Session) -> None:
    if db.scalar(select(User).where(User.is_simulated.is_(True)).limit(1)) is not None:
        return
    skill_by_name = {s.name: s.id for s in db.scalars(select(Skill))}
    skill_ids = list(skill_by_name.values())
    if not skill_ids:
        raise RuntimeError("Skill catalog must be seeded before demo volunteers (call skills.seed_skills first).")
    rng = random.Random(2026)
    now = utcnow()
    for i, name in enumerate(SIM_NAMES):
        phone = f"0899{i:08d}"
        user = User(name=name, phone=phone, password_hash="!", phone_verified=True, is_simulated=True,
                    notify_nearby=False)
        db.add(user)
        db.flush()
        dist, bearing = _sim_offset(user.id)
        user.lat, user.lng = offset_point(*DEMO_CENTER, dist, bearing)
        user.location_updated_at = now
        profile = VolunteerProfile(
            user_id=user.id, is_active=rng.random() > 0.1,
            available_since=now - timedelta(minutes=rng.randint(1, 600)),
            completion_count=rng.choice([0, 0, 1, 2, 3, 5, 8]),
            selection_count=rng.randint(0, 6),
            disaster_experience={"kebakaran": rng.choice([0, 0, 1, 2, 4])},
        )
        db.add(profile)
        for skill_id in rng.sample(skill_ids, min(rng.randint(1, 3), len(skill_ids))):
            db.add(VolunteerSkill(user_id=user.id, skill_id=skill_id,
                                  evidence="certified" if rng.random() < 0.35 else "self_declared",
                                  verified_experience=rng.choice([0, 0, 1, 2, 3, 6])))

    for phone, name, skill_names in DEMO_ACCOUNTS:
        if db.scalar(select(User).where(User.phone == phone)) is not None:
            continue
        lat, lng = offset_point(*DEMO_CENTER, 0.8, 45 if skill_names else 200)
        user = User(name=name, phone=phone, password_hash=hash_password(DEMO_PASSWORD), phone_verified=True,
                    lat=lat, lng=lng, location_updated_at=now)
        db.add(user)
        db.flush()
        if skill_names:
            db.add(VolunteerProfile(user_id=user.id, is_active=True, available_since=now))
            for skill_name in skill_names:
                db.add(VolunteerSkill(user_id=user.id, skill_id=skill_by_name[skill_name],
                                      evidence="certified", verified_experience=2))
    db.commit()
```

- [ ] **Step 14: Update `tests/test_matching.py`**

Replace the `vol()` helper's default skills:
```python
def vol(uid, km, skills=None, active=True, completion=0, fires=0, selection=0, bearing=0):
    lat, lng = offset_point(*SITE, km, bearing)
    return VolunteerInput(
        user_id=uid, lat=lat, lng=lng, is_active=active,
        skills=skills if skills is not None else {"Evakuasi": ("self_declared", 0)},
        completion_count=completion, disaster_experience={"kebakaran": fires}, selection_count=selection,
        available_since=datetime(2026, 1, 1),
    )
```
becomes
```python
def vol(uid, km, skills=None, active=True, completion=0, fires=0, selection=0, bearing=0):
    lat, lng = offset_point(*SITE, km, bearing)
    return VolunteerInput(
        user_id=uid, lat=lat, lng=lng, is_active=active,
        skills=skills if skills is not None else {1: ("self_declared", 0)},
        completion_count=completion, disaster_experience={"kebakaran": fires}, selection_count=selection,
        available_since=datetime(2026, 1, 1),
    )
```

Update every test that passed a string skill name, using skill id `1` as the "matching" skill and `2` as a "different, non-matching" skill throughout:
```python
def test_priority_formula_matches_spec():
    v = vol("a", 1.0, skills={"Evakuasi": ("certified", 3)}, completion=2, fires=1)
    c = score_volunteer(v, "evakuasi", "kebakaran", *SITE, CFG)
```
becomes
```python
def test_priority_formula_matches_spec():
    v = vol("a", 1.0, skills={1: ("certified", 3)}, completion=2, fires=1)
    c = score_volunteer(v, 1, "kebakaran", *SITE, CFG)
```

```python
@pytest.mark.parametrize("v", [
    vol("off", 1, active=False),                          # availability OFF
    vol("noskill", 1, skills={"Logistik": ("certified", 5)}),  # SkillMatch = 0
    vol("far", 5.2),                                      # distance > 5 km
])
def test_hard_filters(v):
    assert score_volunteer(v, "Evakuasi", "kebakaran", *SITE, CFG) is None
```
becomes
```python
@pytest.mark.parametrize("v", [
    vol("off", 1, active=False),                     # availability OFF
    vol("noskill", 1, skills={2: ("certified", 5)}),  # SkillMatch = 0 (different skill_id)
    vol("far", 5.2),                                 # distance > 5 km
])
def test_hard_filters(v):
    assert score_volunteer(v, 1, "kebakaran", *SITE, CFG) is None
```

```python
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
```
becomes
```python
def test_reporter_is_excluded():
    ranked = rank_candidates([vol("reporter", 0.5), vol("other", 2)], 1, "kebakaran", *SITE, CFG,
                             exclude_user_ids={"reporter"})
    assert [c.user_id for c in ranked] == ["other"]


def test_distance_dominates_ranking():
    ranked = rank_candidates([vol("far", 4), vol("near", 0.5), vol("mid", 2)], 1, "kebakaran", *SITE, CFG)
    assert [c.user_id for c in ranked] == ["near", "mid", "far"]


def test_fairness_only_on_near_ties():
    # 0.01 km apart -> near-identical score: lower selection count goes first
    a = vol("a", 1.00, selection=5)
    b = vol("b", 1.02, selection=0, bearing=90)
    ranked = rank_candidates([a, b], 1, "kebakaran", *SITE, CFG)
    assert [c.user_id for c in ranked] == ["b", "a"]
    # 1 km apart -> significant difference: fairness must not override
    c = vol("c", 1.0, selection=9)
    d = vol("d", 2.0, selection=0)
    ranked = rank_candidates([c, d], 1, "kebakaran", *SITE, CFG)
    assert [x.user_id for x in ranked] == ["c", "d"]
```
(`test_diminishing_return_caps_at_10`, `test_fairness_is_pairwise`, `test_exact_tie_breaks_on_distance_then_competency`, and `test_batch_sizes_follow_section_4_10` don't reference skills at all — leave them unchanged.)

- [ ] **Step 15: Update `tests/test_flow.py`**

Add `Skill` to the models import:
```python
from app.db.models import (
    Assignment,
    Need,
    Notification,
    Offer,
    Participant,
    Report,
    User,
    VolunteerProfile,
    VolunteerSkill,
    utcnow,
)
```
becomes
```python
from app.db.models import (
    Assignment,
    Need,
    Notification,
    Offer,
    Participant,
    Report,
    Skill,
    User,
    VolunteerProfile,
    VolunteerSkill,
    utcnow,
)
```
(no new import line needed — `select` is already imported at the top of the file.)

Add a helper right after the `SITE`/`TEXT` constants:
```python
def skill_id_for(db, name: str) -> int:
    return db.scalar(select(Skill).where(Skill.name == name)).id
```

Replace `signup`:
```python
def signup(client, phone, name="User", volunteer_skills=None):
    body = {"name": name, "phone": phone, "password": "rahasia1"}
    if volunteer_skills:
        body |= {"become_volunteer": True, "skills": [{"skill": s} for s in volunteer_skills]}
    r = client.post("/auth/register", json=body)
    assert r.status_code == 200, r.text
    r = client.post("/auth/verify-otp", json={"phone": phone, "code": r.json()["dev_otp"]})
    assert r.status_code == 200, r.text
    token = r.json()["token"]
    return {"Authorization": f"Bearer {token}"}, r.json()["user"]["id"]
```
becomes
```python
def signup(client, db, phone, name="User", volunteer_skills=None):
    body = {"name": name, "phone": phone, "password": "rahasia1"}
    if volunteer_skills:
        body |= {"become_volunteer": True,
                 "skills": [{"skill_id": skill_id_for(db, s)} for s in volunteer_skills]}
    r = client.post("/auth/register", json=body)
    assert r.status_code == 200, r.text
    r = client.post("/auth/verify-otp", json={"phone": phone, "code": r.json()["dev_otp"]})
    assert r.status_code == 200, r.text
    token = r.json()["token"]
    return {"Authorization": f"Bearer {token}"}, r.json()["user"]["id"]
```

Replace `add_volunteers`:
```python
def add_volunteers(db, n, skill="Evakuasi", start_km=0.3, step_km=0.3):
    ids = []
    for i in range(n):
        lat, lng = offset_point(*SITE, start_km + i * step_km, 40 * i)
        u = User(name=f"Relawan {i + 1}", phone=f"0877{i:08d}", password_hash="!", phone_verified=True,
                 lat=lat, lng=lng)
        db.add(u)
        db.flush()
        db.add(VolunteerProfile(user_id=u.id, is_active=True))
        db.add(VolunteerSkill(user_id=u.id, skill=skill))
        ids.append(u.id)
    db.commit()
    return ids
```
becomes
```python
def add_volunteers(db, n, skill_name="P3K", start_km=0.3, step_km=0.3):
    skill_id = skill_id_for(db, skill_name)
    ids = []
    for i in range(n):
        lat, lng = offset_point(*SITE, start_km + i * step_km, 40 * i)
        u = User(name=f"Relawan {i + 1}", phone=f"0877{i:08d}", password_hash="!", phone_verified=True,
                 lat=lat, lng=lng)
        db.add(u)
        db.flush()
        db.add(VolunteerProfile(user_id=u.id, is_active=True))
        db.add(VolunteerSkill(user_id=u.id, skill_id=skill_id))
        ids.append(u.id)
    db.commit()
    return ids
```

Replace `create_active_report`:
```python
def create_active_report(client, headers, quota=2, category="evakuasi"):
    r = client.post("/reports", headers=headers, json={"description": TEXT, "lat": SITE[0], "lng": SITE[1]})
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["report"]["status"] == "draft"
    assert "evakuasi" in [n["category"] for n in data["proposed_needs"]]
    rid = data["report"]["id"]
    r = client.post(f"/reports/{rid}/confirm", headers=headers,
                    json={"needs": [{"category": category, "quota": quota}],
                          "fields": {"kondisi_akses": "gang sempit"}})
    assert r.status_code == 200, r.text
    return rid
```
becomes
```python
def create_active_report(client, headers, db, quota=2, skill_name="P3K"):
    r = client.post("/reports", headers=headers, json={"description": TEXT, "lat": SITE[0], "lng": SITE[1]})
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["report"]["status"] == "draft"
    assert data["proposed_needs"] == []  # manual selection until Task 4 wires real AI proposals
    rid = data["report"]["id"]
    r = client.post(f"/reports/{rid}/confirm", headers=headers,
                    json={"needs": [{"skill_id": skill_id_for(db, skill_name), "quota": quota}],
                          "fields": {}})
    assert r.status_code == 200, r.text
    return rid
```

Now fix every call site of `signup`/`create_active_report` in the same file (each test function that calls them):

`test_volunteer_toggle_and_reporter_can_still_report`:
```python
    h, uid = signup(client, "081200001111", volunteer_skills=["P3K"])
```
becomes
```python
    h, uid = signup(client, db, "081200001111", volunteer_skills=["P3K"])
```

`test_full_dispatch_flow`:
```python
    vols = add_volunteers(db, 8)
    rep_h, rep_id = signup(client, "081200000009", "Pelapor")
    rid = create_active_report(client, rep_h, quota=2)
```
becomes
```python
    vols = add_volunteers(db, 8)
    rep_h, rep_id = signup(client, db, "081200000009", "Pelapor")
    rid = create_active_report(client, rep_h, db, quota=2)
```

`test_no_candidates_is_visible_not_silent`:
```python
    rep_h, _ = signup(client, "081200000010")
    rid = create_active_report(client, rep_h, quota=3, category="medis")
```
becomes
```python
    rep_h, _ = signup(client, db, "081200000010")
    rid = create_active_report(client, rep_h, db, quota=3)
```

`test_reporter_never_matched_to_own_report`:
```python
    add_volunteers(db, 2)
    h, uid = signup(client, "081200000011", volunteer_skills=["Evakuasi"])
    client.post("/me/location", headers=h, json={"lat": SITE[0], "lng": SITE[1]})
    rid = create_active_report(client, h)
```
becomes
```python
    add_volunteers(db, 2)
    h, uid = signup(client, db, "081200000011", volunteer_skills=["P3K"])
    client.post("/me/location", headers=h, json={"lat": SITE[0], "lng": SITE[1]})
    rid = create_active_report(client, h, db)
```

`test_volunteer_api_accept_and_task`:
```python
    rep_h, _ = signup(client, "081200000012")
    vol_h, vol_id = signup(client, "081200000013", "Relawan Asli", volunteer_skills=["Evakuasi"])
    client.post("/me/location", headers=vol_h, json={"lat": SITE[0] + 0.005, "lng": SITE[1]})
    rid = create_active_report(client, rep_h, quota=1)
```
becomes
```python
    rep_h, _ = signup(client, db, "081200000012")
    vol_h, vol_id = signup(client, db, "081200000013", "Relawan Asli", volunteer_skills=["P3K"])
    client.post("/me/location", headers=vol_h, json={"lat": SITE[0] + 0.005, "lng": SITE[1]})
    rid = create_active_report(client, rep_h, db, quota=1)
```

`test_sighting_and_nearby_widget`:
```python
    rep_h, _ = signup(client, "081200000014")
    other_h, _ = signup(client, "081200000015")
    client.post("/me/location", headers=other_h, json={"lat": SITE[0] + 0.01, "lng": SITE[1]})
    rid = create_active_report(client, rep_h)
```
becomes
```python
    rep_h, _ = signup(client, db, "081200000014")
    other_h, _ = signup(client, db, "081200000015")
    client.post("/me/location", headers=other_h, json={"lat": SITE[0] + 0.01, "lng": SITE[1]})
    rid = create_active_report(client, rep_h, db)
```

`test_config_is_tunable`:
```python
    h, _ = signup(client, "081200000016")
```
becomes
```python
    h, _ = signup(client, db, "081200000016")
```
(this test's signature is `def test_config_is_tunable(client, db):` already — `db` is already available.)

`test_register_login_and_otp` and `test_report_requires_account` don't call `signup`/`create_active_report` — leave unchanged.

- [ ] **Step 16: Update `tests/test_rules.py`**

Remove the dead import and the deleted feature's test:
```python
from app.services.needs import map_needs
```
(delete this line)
```python
def test_need_mapping_for_fire():
    cats = [n["category"] for n in map_needs(REPORT, "kebakaran", DEFAULTS["need_catalog"])]
    assert cats == ["pemadaman_awal", "evakuasi", "akses"]


```
(delete this whole test function — `needs.py` no longer exists).

- [ ] **Step 17: Run the full test suite**

Run: `cd backend && .venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass. If anything fails, re-check the specific file/line referenced in the traceback against the steps above — the most common miss is a leftover `.skill` (string) or `.category` reference in a file not listed here; search with `grep -rn "\.category\b\|need\.skill\b\|s\.skill\b" backend/app` and fix any remaining hit the same way as the matching pattern in this task.

- [ ] **Step 18: Commit**

```bash
git add backend/app/db/models.py backend/app/core/app_config.py backend/app/services/matching.py backend/app/services/dispatch.py backend/app/api/reports.py backend/app/api/volunteer.py backend/app/api/me.py backend/app/api/auth.py backend/app/services/simulation.py backend/tests/test_matching.py backend/tests/test_flow.py backend/tests/test_rules.py
git rm backend/app/services/needs.py
git commit -m "refactor: migrate skill representation to Skill-catalog IDs"
```

---

### Task 3: Cross-skill credit

**Files:**
- Modify: `backend/app/db/models.py` (`Assignment.credited_skill_ids`)
- Modify: `backend/app/services/dispatch.py` (`accepted_count`, `apply_cross_skill_credit`, hook into `accept_offer`)
- Modify: `backend/app/services/confirmation.py` (`apply_experience`)
- Modify: `backend/tests/test_flow.py` (new cross-credit test)

**Interfaces:**
- Consumes: `Need.skill_id`, `VolunteerSkill.skill_id` from Task 2.
- Produces: `dispatch.apply_cross_skill_credit(db: Session, assignment: Assignment, report: Report) -> None`, called from `accept_offer`. `accepted_count(db, need_id)` now also counts credited assignments.

- [ ] **Step 1: Write the failing test**

Add to `backend/tests/test_flow.py`, after `test_full_dispatch_flow`:
```python
def test_cross_skill_credit_fills_second_need_without_separate_alarm(client, db):
    rep_h, _ = signup(client, db, "081200000020", "Pelapor Multi")
    p3k_id = skill_id_for(db, "P3K")
    apar_id = skill_id_for(db, "Penggunaan APAR")

    # one volunteer with BOTH skills, close by
    multi_h, multi_id = signup(client, db, "081200000021", "Relawan Serba Bisa",
                               volunteer_skills=["P3K", "Penggunaan APAR"])
    client.post("/me/location", headers=multi_h, json={"lat": SITE[0] + 0.005, "lng": SITE[1]})

    r = client.post("/reports", headers=rep_h, json={"description": TEXT, "lat": SITE[0], "lng": SITE[1]})
    rid = r.json()["report"]["id"]
    r = client.post(f"/reports/{rid}/confirm", headers=rep_h,
                    json={"needs": [{"skill_id": p3k_id, "quota": 1}, {"skill_id": apar_id, "quota": 1}],
                          "fields": {}})
    assert r.status_code == 200, r.text

    offers = offers_of(db, rid)
    p3k_offer = next(o for o in offers if db.get(Need, o.need_id).skill_id == p3k_id)
    assert p3k_offer.volunteer_id == multi_id  # only volunteer in range

    a = dispatch.accept_offer(db, p3k_offer)
    db.commit()

    apar_need = db.scalar(select(Need).where(Need.report_id == rid, Need.skill_id == apar_id))
    assert apar_need.status == "penuh"  # credited without a separate offer/alarm
    assert dispatch.accepted_count(db, apar_need.id) == 1
    db.expire_all()
    assert sorted(db.get(Assignment, a.id).credited_skill_ids) == [apar_id]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_flow.py::test_cross_skill_credit_fills_second_need_without_separate_alarm -v`
Expected: FAIL — `AttributeError` on `credited_skill_ids` (column doesn't exist yet) and/or `apar_need.status` stays `"belum_ada"` (no credit logic yet).

- [ ] **Step 3: Add `Assignment.credited_skill_ids`**

In `backend/app/db/models.py`, in the `Assignment` class, add the new column after `order_number`:
```python
    role: Mapped[str] = mapped_column(String(20))  # utama | tambahan (4.11)
    order_number: Mapped[int] = mapped_column(Integer)  # "relawan ke-N" for this need
```
becomes
```python
    role: Mapped[str] = mapped_column(String(20))  # utama | tambahan (4.11)
    order_number: Mapped[int] = mapped_column(Integer)  # "relawan ke-N" for this need
    # skill_ids of OTHER needs on this report this same assignment also satisfies,
    # beyond need_id (the one actually dispatched/alarmed) -- cross-skill credit.
    credited_skill_ids: Mapped[list[int]] = mapped_column(JSON, default=list)
```

- [ ] **Step 4: Update `accepted_count` in `dispatch.py`**

```python
def accepted_count(db: Session, need_id: str) -> int:
    return db.scalar(select(func.count()).select_from(Assignment)
                     .where(Assignment.need_id == need_id, Assignment.status != "dilepas")) or 0
```
becomes
```python
def accepted_count(db: Session, need_id: str) -> int:
    need = db.get(Need, need_id)
    assignments = db.scalars(select(Assignment).where(Assignment.report_id == need.report_id,
                                                       Assignment.status != "dilepas")).all()
    return sum(1 for a in assignments if a.need_id == need_id or need.skill_id in (a.credited_skill_ids or []))
```

- [ ] **Step 5: Add `apply_cross_skill_credit` and call it from `accept_offer`**

Add this new function to `dispatch.py`, right after `accept_offer`:
```python
def apply_cross_skill_credit(db: Session, assignment: Assignment, report: Report) -> None:
    """After one need's alarm is accepted, check whether the volunteer's other
    skills also satisfy other still-open needs on the same report, and credit
    them there too -- without a separate alarm/offer (design doc Part 2)."""
    profile = db.get(VolunteerProfile, assignment.volunteer_id)
    if profile is None:
        return
    my_skill_ids = {s.skill_id for s in profile.skills}
    credited: list[int] = []
    for need in report.needs:
        if need.id == assignment.need_id or need.status == "selesai":
            continue
        if need.skill_id not in my_skill_ids:
            continue
        if remaining_need(db, need) <= 0:
            continue
        credited.append(need.skill_id)
    if credited:
        assignment.credited_skill_ids = credited
        db.flush()
        for need in report.needs:
            if need.skill_id in credited:
                refresh_need_status(db, need)
```

`remaining_need` currently takes a `Need` object (`remaining_need(db, need)` -- check the existing signature):
```python
def remaining_need(db: Session, need: Need) -> int:
    return max(0, need.quota - accepted_count(db, need.id))
```
This already takes a `Need`, so `remaining_need(db, need)` in the new function above is correct as written (no change needed to `remaining_need` itself).

Now call the new function from `accept_offer`, right after `refresh_need_status(db, need)`:
```python
    ensure_participant(db, report.id, offer.volunteer_id, "relawan")
    db.flush()
    refresh_need_status(db, need)

    reporter = db.get(User, report.reporter_id)
```
becomes
```python
    ensure_participant(db, report.id, offer.volunteer_id, "relawan")
    db.flush()
    refresh_need_status(db, need)
    apply_cross_skill_credit(db, assignment, report)

    reporter = db.get(User, report.reporter_id)
```

- [ ] **Step 6: Update `apply_experience` in `confirmation.py` to credit every skill, not just the primary one**

```python
def apply_experience(db: Session, a: Assignment, disaster_type: str) -> None:
    """Section 4.12 -- run only after the disaster is resolved."""
    profile = db.get(VolunteerProfile, a.volunteer_id)
    if profile is None:
        return
    exp = dict(profile.disaster_experience or {})
    exp[disaster_type] = exp.get(disaster_type, 0) + 1
    profile.disaster_experience = exp  # reassign so the JSON change is persisted
    if a.role == "utama":
        profile.completion_count += 1
        need = db.get(Need, a.need_id)
        for s in profile.skills:
            if s.skill.lower() == need.skill.lower():
                s.verified_experience += 1
                break
```
becomes
```python
def apply_experience(db: Session, a: Assignment, disaster_type: str) -> None:
    """Section 4.12 -- run only after the disaster is resolved."""
    profile = db.get(VolunteerProfile, a.volunteer_id)
    if profile is None:
        return
    exp = dict(profile.disaster_experience or {})
    exp[disaster_type] = exp.get(disaster_type, 0) + 1
    profile.disaster_experience = exp  # reassign so the JSON change is persisted
    if a.role == "utama":
        profile.completion_count += 1
        need = db.get(Need, a.need_id)
        credited_ids = set(a.credited_skill_ids or [])
        if need is not None:
            credited_ids.add(need.skill_id)
        for s in profile.skills:
            if s.skill_id in credited_ids:
                s.verified_experience += 1
```

- [ ] **Step 7: Run the new test to verify it passes**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_flow.py::test_cross_skill_credit_fills_second_need_without_separate_alarm -v`
Expected: PASS.

- [ ] **Step 8: Run the full test suite**

Run: `cd backend && .venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass (including `test_full_dispatch_flow`'s experience assertions, unaffected since that test's volunteers have only one skill each).

- [ ] **Step 9: Commit**

```bash
git add backend/app/db/models.py backend/app/services/dispatch.py backend/app/services/confirmation.py backend/tests/test_flow.py
git commit -m "feat: cross-skill credit -- one acceptance can fill multiple needs"
```

---

### Task 4: Rewrite the Groq extraction contract and wire it into `reports.py`

**Files:**
- Modify: `backend/app/services/extraction.py` (full rewrite of the schema/prompt/fallback)
- Modify: `backend/app/api/reports.py` (`StructuredIn`, `create_report`)
- Modify: `backend/tests/test_rules.py` (extraction tests rewritten for the new schema)
- Modify: `backend/tests/test_flow.py` (`create_active_report`'s `proposed_needs == []` assertion becomes real again for at least one flow)

**Interfaces:**
- Consumes: `Skill` list from `skills_service.list_skills(db)` (Task 1).
- Produces: `extraction.extract(text: str, skills: list[Skill]) -> Extraction` where `Extraction` has `.title: str`, `.description: str`, `.needs: list[dict]` (each `{"skill_id": int, "quota": int}`), `.source`, `.elapsed_ms`, `.note`, `.incident_type`. `extraction.FIELDS = ["title", "description"]`.

- [ ] **Step 1: Write the failing tests for the new schema**

Replace the extraction-related tests in `backend/tests/test_rules.py`. The full new file:
```python
"""Quorum table and extraction fallback."""
import asyncio

import pytest
from sqlalchemy import select

from app.core.app_config import DEFAULTS
from app.core.config import get_settings
from app.db.models import Skill
from app.services import extraction
from app.services.confirmation import threshold_proportional, threshold_simple
from app.services.skills import seed_skills

# Section 4.13 reference table, N -> threshold (1..100)
TABLE = """
1→1   11→7   21→12  31→16  41→21  51→25  61→25  71→29  81→33  91→37
2→2   12→8   22→12  32→16  42→21  52→25  62→25  72→29  82→33  92→37
3→3   13→8   23→12  33→17  43→22  53→25  63→26  73→30  83→34  93→38
4→3   14→9   24→12  34→17  44→22  54→25  64→26  74→30  84→34  94→38
5→4   15→9   25→13  35→18  45→23  55→25  65→26  75→30  85→34  95→38
6→5   16→10  26→13  36→18  46→23  56→25  66→27  76→31  86→35  96→39
7→5   17→11  27→14  37→19  47→24  57→25  67→27  77→31  87→35  97→39
8→6   18→11  28→14  38→19  48→24  58→25  68→28  78→32  88→36  98→40
9→7   19→12  29→15  39→20  49→25  59→25  69→28  79→32  89→36  99→40
10→7  20→12  30→15  40→20  50→25  60→25  70→28  80→32  90→36  100→40
"""


def test_quorum_matches_reference_table():
    pairs = [tuple(map(int, cell.split("→"))) for cell in TABLE.split()]
    assert len(pairs) == 100
    for n, expected in pairs:
        assert threshold_proportional(n) == expected, n


def test_simple_quorum():
    assert [threshold_simple(n) for n in (1, 2, 3, 4, 10)] == [1, 2, 3, 2, 5]


REPORT = ("Tolong! Kebakaran rumah di Gang Mawar RT 05, api merambat ke rumah sebelah. "
          "Ada lansia terjebak di lantai 2. Gang sempit, mobil damkar susah masuk.")


def test_no_api_key_falls_back_without_blocking(db):
    seed_skills(db)
    skills = list(db.scalars(select(Skill)))
    result = asyncio.run(extraction.extract(REPORT, skills))
    assert result.source == "rule"
    assert result.needs == []
    assert result.title
    assert result.description == REPORT
    assert result.incident_type == "kebakaran"


def test_llm_timeout_falls_back(monkeypatch, db):
    seed_skills(db)
    skills = list(db.scalars(select(Skill)))
    settings = get_settings()
    monkeypatch.setattr(settings, "groq_api_key", "sk-test")
    monkeypatch.setattr(settings, "llm_timeout_seconds", 0.2)

    async def slow(_text, _skills):
        await asyncio.sleep(5)

    monkeypatch.setattr(extraction, "_llm_extract", slow)
    result = asyncio.run(extraction.extract(REPORT, skills))
    assert result.source == "rule"
    assert "batas waktu" in result.note
    assert result.elapsed_ms < 2000


def test_llm_error_falls_back(monkeypatch, db):
    seed_skills(db)
    skills = list(db.scalars(select(Skill)))
    settings = get_settings()
    monkeypatch.setattr(settings, "groq_api_key", "sk-test")

    async def boom(_text, _skills):
        raise RuntimeError("503")

    monkeypatch.setattr(extraction, "_llm_extract", boom)
    result = asyncio.run(extraction.extract(REPORT, skills))
    assert result.source == "rule"


def test_llm_success_maps_needs_to_real_skill_ids(monkeypatch, db):
    seed_skills(db)
    skills = list(db.scalars(select(Skill)))
    p3k = next(s for s in skills if s.name == "P3K")
    settings = get_settings()
    monkeypatch.setattr(settings, "groq_api_key", "sk-test")

    async def fake_llm(_text, _skills):
        return {"title": "Kebakaran di Gang Mawar", "description": REPORT,
                "needs": [{"skill_id": p3k.id, "quota": 2}]}

    monkeypatch.setattr(extraction, "_llm_extract", fake_llm)
    result = asyncio.run(extraction.extract(REPORT, skills))
    assert result.source == "llm"
    assert result.title == "Kebakaran di Gang Mawar"
    assert result.needs == [{"skill_id": p3k.id, "quota": 2}]
    assert result.incident_type == "kebakaran"


def test_incident_type_classified_from_raw_text_regardless_of_ai():
    assert extraction._incident_type_from("banjir besar merendam kampung") == "banjir"
    assert extraction._incident_type_from("tidak jelas apa yang terjadi") == "kebakaran"  # default


@pytest.mark.parametrize("phone,masked", [("081234567890", "0812****7890"), ("0812345678", "0812**5678")])
def test_mask_phone(phone, masked):
    from app.core.security import mask_phone
    assert mask_phone(phone) == masked
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_rules.py -v`
Expected: FAIL — `extraction.extract()` still takes only `text` (missing `skills` arg), `_incident_type_from` currently takes a field value not raw text, `.needs`/`.title`/`.description` don't exist on `Extraction` yet.

- [ ] **Step 3: Rewrite `extraction.py`**

Replace the entire file:
```python
"""AI extraction of a free-text report: title, description, and required
skills+quota, matched against the Skill catalog (design doc Part 1).

Reliability rules:
  * hard timeout (default 5 s); on timeout / error / refusal / no API key the
    fallback below runs instead, so submission is never blocked;
  * incident_type classification is a separate, always-on regex step, run
    against the raw report text regardless of whether the AI call succeeds --
    it was not one of the four requested extraction fields.
"""
import asyncio
import json
import logging
import re
import time
from dataclasses import dataclass, field

from pydantic import BaseModel

from ..core.config import get_settings
from ..db.models import Skill

log = logging.getLogger("reliefsync.extraction")

FIELDS = ["title", "description"]
FIELD_LABELS = {"title": "Judul", "description": "Deskripsi"}
UNKNOWN = "belum diketahui"

DOMAIN_RULES = """Aturan pemilihan skill (dari dokumen "Skill Relawan -- ReliefSync"):
1. Hanya pilih skill dari daftar yang diberikan, dengan skill_id yang persis sama.
2. Tidak ada pewarisan otomatis antar-skill -- mis. P3K TIDAK berarti CPR/RJP, Berenang
   TIDAK berarti kompetensi water rescue.
3. "Berenang" hanya relevan jika teks menyebutkan genangan/banjir tinggi secara eksplisit.
4. Jangan pilih skill untuk tugas umum (distribusi bantuan, pendataan, komunikasi) --
   itu bukan skill teknis.
5. Jangan mengarang kebutuhan yang tidak didukung oleh teks laporan."""


class NeedOut(BaseModel):
    skill_id: int
    quota: int


class ExtractionResult(BaseModel):
    title: str
    description: str
    needs: list[NeedOut]


@dataclass
class Extraction:
    title: str
    description: str
    needs: list[dict] = field(default_factory=list)  # [{skill_id, quota}]
    source: str = "rule"  # llm | rule
    elapsed_ms: int = 0
    note: str | None = None
    incident_type: str = "kebakaran"


# ---------------------------------------------------------------------------
# Incident-type classification -- always regex-based, independent of the LLM.
# ---------------------------------------------------------------------------
_INCIDENT_PATTERNS = [
    ("kebakaran", r"kebakaran|terbakar|api|asap|korslet|korsleting|hangus|menyala|meledak"),
    ("banjir", r"banjir|genangan|air naik|terendam"),
    ("longsor", r"longsor"),
    ("gempa", r"gempa"),
]


def _incident_type_from(text: str) -> str:
    lowered = (text or "").lower()
    for itype, pattern in _INCIDENT_PATTERNS:
        if re.search(pattern, lowered):
            return itype
    return "kebakaran"


# ---------------------------------------------------------------------------
# Fallback when the LLM is unavailable/times out/errors (NFR-9/10): never
# block submission. The reporter adjusts needs manually before confirming.
# ---------------------------------------------------------------------------
def _fallback_title(text: str) -> str:
    first_sentence = re.split(r"(?<=[.!?\n])\s+", text.strip(), maxsplit=1)[0]
    return first_sentence[:80] if first_sentence else UNKNOWN


def rule_based_extract(text: str) -> tuple[str, str]:
    return _fallback_title(text), text.strip() or UNKNOWN


# ---------------------------------------------------------------------------
# LLM extractor (Groq, OpenAI-compatible chat completions)
# ---------------------------------------------------------------------------
GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions"

SYSTEM_PROMPT_TEMPLATE = """Kamu adalah pengekstrak data untuk aplikasi tanggap bencana ReliefSync.
Dari laporan warga, hasilkan:
- title: judul singkat kejadian (maks 10 kata).
- description: ringkasan kejadian dalam Bahasa Indonesia (termasuk lokasi dan kondisi akses
  yang disebutkan di teks, jika ada) -- boleh diparafrase, tidak perlu kata-per-kata.
- needs: daftar {{skill_id, quota}} -- skill yang benar-benar dibutuhkan berdasarkan teks,
  dan estimasi jumlah relawan per skill.

Daftar skill yang tersedia (HANYA pilih dari sini, dengan skill_id persis):
{catalog}

{domain_rules}

Balas HANYA dengan JSON valid (tanpa teks lain, tanpa markdown) sesuai skema ini:
{schema}"""


def _build_system_prompt(skills: list[Skill]) -> str:
    catalog = "\n".join(f"- skill_id={s.id}: {s.name}" for s in skills)
    schema = json.dumps(ExtractionResult.model_json_schema(), ensure_ascii=False)
    return SYSTEM_PROMPT_TEMPLATE.format(catalog=catalog, domain_rules=DOMAIN_RULES, schema=schema)


async def _llm_extract(text: str, skills: list[Skill]) -> dict:
    import httpx  # already a project dependency

    s = get_settings()
    system_prompt = _build_system_prompt(skills)
    async with httpx.AsyncClient(timeout=s.llm_timeout_seconds) as client:
        resp = await client.post(
            GROQ_API_URL,
            headers={"Authorization": f"Bearer {s.groq_api_key}"},
            json={
                "model": s.llm_model,
                "temperature": 0,
                "max_tokens": 1024,
                "response_format": {"type": "json_object"},
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": f"<laporan>\n{text}\n</laporan>"},
                ],
            },
        )
        resp.raise_for_status()
        data = resp.json()

    choice = data["choices"][0]
    if choice.get("finish_reason") == "content_filter":
        raise RuntimeError("LLM refused the request (content_filter)")
    content = choice["message"]["content"]
    return ExtractionResult.model_validate_json(content).model_dump()


def _sanitize_needs(raw_needs: list[dict], valid_skill_ids: set[int]) -> list[dict]:
    """Drop any need whose skill_id isn't a real catalog entry -- the LLM must
    never be trusted to only emit valid ids, even with the catalog in-prompt."""
    out, seen = [], set()
    for n in raw_needs:
        skill_id = n["skill_id"]
        if skill_id not in valid_skill_ids or skill_id in seen:
            continue
        seen.add(skill_id)
        out.append({"skill_id": skill_id, "quota": max(1, int(n["quota"]))})
    return out


async def extract(text: str, skills: list[Skill]) -> Extraction:
    start = time.perf_counter()
    s = get_settings()
    incident_type = _incident_type_from(text)
    valid_skill_ids = {sk.id for sk in skills}
    note = None

    if s.groq_api_key and text.strip():
        try:
            raw = await asyncio.wait_for(_llm_extract(text, skills), timeout=s.llm_timeout_seconds + 0.5)
            return Extraction(
                title=raw["title"].strip() or UNKNOWN,
                description=raw["description"].strip() or text.strip(),
                needs=_sanitize_needs(raw["needs"], valid_skill_ids),
                source="llm",
                elapsed_ms=int((time.perf_counter() - start) * 1000),
                incident_type=incident_type,
            )
        except (TimeoutError, asyncio.TimeoutError):
            note = "AI tidak merespons dalam batas waktu; pilih kebutuhan secara manual."
            log.warning("LLM extraction timed out; using fallback")
        except Exception as exc:  # noqa: BLE001 -- any AI failure must fall back (NFR-10)
            note = "AI tidak tersedia; pilih kebutuhan secara manual."
            log.warning("LLM extraction failed (%s); using fallback", exc)
    elif not s.groq_api_key:
        note = "AI tidak dikonfigurasi; pilih kebutuhan secara manual."

    title, description = rule_based_extract(text)
    return Extraction(
        title=title,
        description=description,
        needs=[],
        source="rule",
        elapsed_ms=int((time.perf_counter() - start) * 1000),
        note=note,
        incident_type=incident_type,
    )
```

- [ ] **Step 4: Run the extraction tests to verify they pass**

Run: `cd backend && .venv/Scripts/python.exe -m pytest tests/test_rules.py -v`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Wire the new contract into `reports.py`**

Replace `StructuredIn`:
```python
class StructuredIn(BaseModel):
    """Direct structured form -- the reporter may skip free text (5.5 step 2)."""
    jenis_kejadian: str = "kebakaran permukiman"
    lokasi_disebutkan: str = ""
    kondisi_akses: str = ""
    kebutuhan_dinyatakan: str = ""
```
becomes
```python
class StructuredIn(BaseModel):
    """Direct structured form -- the reporter may skip free text (5.5 step 2)."""
    title: str = ""
    description: str = Field(default="", max_length=4000)
```

Replace the extraction section of `create_report` (the interim version from Task 2):
```python
    if body.input_mode == "form" and body.structured is not None:
        s = body.structured.model_dump()
        fields = {k: {"value": (v.strip() or extraction.UNKNOWN), "evidence": None,
                      "confidence": 1.0 if v.strip() else 0.0} for k, v in s.items()}
        source, elapsed, note = "form", 0, "Diisi langsung lewat formulir."
        incident_type = extraction._incident_type_from(s["jenis_kejadian"])
    else:
        result = await extraction.extract(text)
        fields, source, elapsed, note = result.fields, result.source, result.elapsed_ms, result.note
        incident_type = result.incident_type

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
        "proposed_needs": [],  # manual selection only until Task 4 wires the new extraction contract
        "catalog": catalog_payload(db),
    }
```
becomes
```python
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
```

- [ ] **Step 6: Update `test_flow.py`'s `create_active_report` assertion**

The Task 2 interim assertion:
```python
    assert data["proposed_needs"] == []  # manual selection until Task 4 wires real AI proposals
```
stays correct and unchanged for `create_active_report`'s callers, since no `GROQ_API_KEY` is set in the test environment (`conftest.py` sets `"GROQ_API_KEY": ""`), so `extraction.extract()` always takes the fallback path and returns `needs=[]` regardless of Task 4's changes. No edit needed here — just re-run the suite to confirm.

- [ ] **Step 7: Run the full test suite**

Run: `cd backend && .venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass.

- [ ] **Step 8: Manual smoke check of the Groq call shape (optional but recommended)**

If a real `GROQ_API_KEY` is available, run the backend locally (`cd backend && .venv/Scripts/python.exe -m uvicorn app.main:app --reload`), set `GROQ_API_KEY` in `.env`, and POST a real report through `/reports` (e.g. via the `/docs` Swagger UI) with text like `"Kebakaran rumah di Gang Mawar, ada lansia terjebak, butuh P3K dan alat pemadam."` — confirm the response's `proposed_needs` contains real `skill_id`s matching `P3K` and `Penggunaan APAR` from `GET /needs/catalog`, and `title`/`description` are sensible. This step has no automated assertion; skip if no Groq key is available yet and rely on the fallback-path tests instead.

- [ ] **Step 9: Commit**

```bash
git add backend/app/services/extraction.py backend/app/api/reports.py backend/tests/test_rules.py
git commit -m "feat: rewrite extraction contract for skill-catalog-based needs (Groq)"
```

---

### Task 5: Regenerate the Supabase schema reference and update docs

**Files:**
- Modify: `backend/supabase/schema.sql` (regenerated, not hand-edited)
- Modify: `ReliefSync/README.md`

**Interfaces:** none (documentation/reference-file task only).

- [ ] **Step 1: Regenerate `supabase/schema.sql`**

Run:
```bash
cd backend && .venv/Scripts/python.exe -m scripts.export_schema > supabase/schema.sql
```
This overwrites the file with fresh DDL reflecting `Skill`, the FK columns on `VolunteerSkill`/`Need`, and `Assignment.credited_skill_ids` — matching the file's own header comment ("do not edit by hand").

- [ ] **Step 2: Verify the regenerated file looks right**

Run: `grep -n "CREATE TABLE skills\|skill_id\|credited_skill_ids" backend/supabase/schema.sql`
Expected: shows a `CREATE TABLE skills (...)` block, `skill_id INTEGER` columns on `volunteer_skills` and `needs`, and a `credited_skill_ids` column on `assignments`.

- [ ] **Step 3: Update `README.md`**

In the tech-summary table, update the AI row (it currently still says "Claude" from before the Groq switch, plus the need-mapping description needs to reflect the new pipeline):
```markdown
| AI | Groq (`llama-3.3-70b-versatile`, batas 5 dtk) + fallback berbasis aturan | `backend/app/services/extraction.py` |
```
becomes
```markdown
| AI | Groq (`llama-3.3-70b-versatile`, batas 5 dtk): judul, deskripsi, skill+kuota dari katalog 12 skill (`skills` table) | `backend/app/services/extraction.py` |
```

In Section 4 ("Struktur"), update the file listing to include the new `db/models.py`/`core/` split (already partially updated in an earlier session) and add `services/skills.py`:
```
    services/
      matching.py        # Section 4: hard filter, priority score, fairness, tie-break, ukuran batch
      dispatch.py        # batch alarm, eskalasi, terima/tolak, Utama vs Tambahan
      confirmation.py    # konfirmasi selesai bersama, AFK, 24 jam, update pengalaman
      extraction.py      # Groq + fallback aturan, bukti wajib dari teks asli
      needs.py           # pemetaan kebutuhan berbasis aturan
      trust.py, agencies.py, notify.py, simulation.py, storage.py, geo.py
```
becomes
```
    services/
      matching.py        # Section 4: hard filter, priority score, fairness, tie-break, ukuran batch
      dispatch.py        # batch alarm, eskalasi, terima/tolak, Utama vs Tambahan, cross-skill credit
      confirmation.py    # konfirmasi selesai bersama, AFK, 24 jam, update pengalaman
      extraction.py      # Groq: judul/deskripsi/skill+kuota dari katalog skills, fallback manual
      skills.py          # katalog 12 skill relawan (seed + baca)
      trust.py, agencies.py, notify.py, simulation.py, storage.py, geo.py
```

Also update the "Open items" table entry for need mapping (#14/Section 4.10 note) if it references the old regex mapper by name -- check for any remaining mentions:
Run: `grep -n "need_catalog\|needs.py\|map_needs" README.md`
If any lines are found referencing the deleted mechanism, update them to describe the new Groq-driven, skill-catalog-based need identification instead, following the same style as the surrounding table rows.

- [ ] **Step 4: Final full-suite run**

Run: `cd backend && .venv/Scripts/python.exe -m pytest -q`
Expected: all tests pass — this is the final verification for the whole plan.

- [ ] **Step 5: Commit**

```bash
git add backend/supabase/schema.sql README.md
git commit -m "docs: regenerate schema reference and update README for skill catalog"
```
