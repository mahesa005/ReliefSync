# Skill-Based Report Extraction & Cross-Skill Dispatch — Design

## Context

Today's pipeline:
- `extraction.py` pulls 4 evidence-anchored fields (`jenis_kejadian`, `lokasi_disebutkan`, `kondisi_akses`, `kebutuhan_dinyatakan`) via an LLM call, enforcing that every value's evidence snippet literally appears in the report text.
- `needs.py` maps report text to one of 6 fixed categories via regex (`CATEGORY_RULES`); each category has exactly one skill and a fixed quota from `app_config.DEFAULTS["need_catalog"]`.
- `matching.py` matches volunteers to a need's skill via exact case-insensitive string comparison against `VolunteerSkill.skill` (free text).
- `dispatch.py` runs fully independent batch/escalation per `Need` row (Section 4.10 batching), with no awareness of other needs on the same report.

This spec replaces the regex category system with a real, reviewed 12-skill taxonomy ("Skill Relawan — ReliefSync", IFest 2026 Tim STEICON) driven directly by the LLM, and makes dispatch aware that one volunteer's multiple skills can satisfy multiple needs at once.

## Scope

Two coupled parts, delivered together since Part 2 consumes Part 1's schema:
1. **Extraction & Skill Catalog** — data model + Groq extraction contract
2. **Cross-Skill Credit Dispatch** — `dispatch.py` enhancement

## Part 1: Extraction & Skill Catalog

### Data model changes (`db/models.py`)

- New `Skill` table: `id` (PK, autoincrement), `name` (unique string). Seeded at startup (same pattern as `agencies.seed_agencies()`) with the 12-skill catalog:
  P3K, CPR / RJP, Penanganan perdarahan, Penggunaan AED, Pemasangan bidai, Penggunaan tandu, Teknik memindahkan korban, Mengemudi motor, Mengemudi mobil, Dukungan Psikologis Awal / PFA, Penggunaan APAR, Berenang.
- `VolunteerSkill.skill: str` → `VolunteerSkill.skill_id: int` FK → `skills.id`. `evidence` and `verified_experience` columns unchanged.
- `Need.category: str` + `Need.skill: str` → `Need.skill_id: int` FK → `skills.id`. `category` is dropped entirely — `Skill.name` now serves as the display label everywhere `need_catalog[category]["label"]` was used (`reports.py`, `volunteer.py`, `dispatch.py`).
- `need_catalog` entry removed from `app_config.DEFAULTS` (superseded by the `skills` table + direct LLM output).
- No manual SQL/migration script: `Skill` creates itself via the existing `Base.metadata.create_all()` call in `main.py`'s `init_db()`, in both SQLite (local) and Supabase (next Railway deploy) — same mechanism every other table already uses.

### Extraction contract (`extraction.py`)

One Groq call replaces the old 4-field schema, producing:
- `title: str` — short headline
- `description: str` — free-text summary (absorbs what used to be separate `lokasi_disebutkan`/`kondisi_akses`/`kebutuhan_dinyatakan` fields — no longer separately structured)
- `needs: [{skill_id: int, quota: int}]` — one entry per required skill; `quota` is the LLM's own estimate per skill (acknowledged as a rough guess to be tuned via real testing later)

System prompt must include:
- The full skill catalog (`id` + `name`), fetched from the DB at call time, so the LLM can only select valid `skill_id`s
- Domain rules distilled from the "Skill Relawan" reference doc: no automatic inheritance between skills (e.g. P3K does not imply CPR), "Berenang" (swimming) is only relevant for high-water flood contexts, general/non-technical tasks (distribution, registration, communication) are excluded from skill selection

**Fetching the catalog** follows the existing service-layer convention (matches `agencies.py`'s `suggest(db: Session, ...)`): a new `services/skills.py` exposes `list_skills(db: Session) -> list[Skill]` (a plain `select(Skill)` query) — `extraction.py` does not touch the DB itself, staying consistent with its current DB-agnostic design. `extraction.extract()`'s signature changes from `extract(text: str)` to `extract(text: str, skills: list[Skill])`; the caller (`reports.py`, which already holds a request-scoped `db: Session`) fetches the list via `skills_service.list_skills(db)` and passes it in.

**Dropped**: the strict verbatim-evidence enforcement (`enforce_evidence()`) the old schema had. `title`/`description` are LLM-authored summaries, not extracted spans, so "evidence must literally appear in the text" doesn't apply to this schema. This is a deliberate behavior change from today.

### Fallback (Groq unavailable/timeout/no key)

No regex fallback across the 12 skills (too fragile to build reliably for a hackathon timeline). Instead: `title`/`description` derive trivially from the raw report text, and `needs` returns empty with a note explaining why. The reporter's existing "adjust needs before confirming" step (FR-4.2) is the fallback — they manually pick skills/quotas from the same catalog. Submission is never blocked, consistent with the existing NFR-9/10 principle.

### Matching (`matching.py`)

`skill_matches()` simplifies from case-insensitive string comparison to a direct `skill_id ==` integer comparison.

### Other touch points

- `reports.py`'s `StructuredIn` (manual/no-AI submission path) fields update to the new schema.
- `simulation.py`'s demo volunteers get hardcoded skills remapped from the old 6 category-skills to real entries from the 12-skill catalog (a spread relevant to the demo's fire scenario, per the reference doc's Section 5 relevance table).
- Tests (`test_rules.py`, `test_flow.py`, `test_matching.py`) rewritten against the new schema.

## Part 2: Cross-Skill Credit Dispatch

### Problem

Today, `dispatch.py` runs fully independent batch escalation per `Need` row. Recruiting for one skill has zero awareness of other skills needed on the same report, even when a candidate has multiple matching skills.

### Algorithm

1. Needs remain per-skill with their own quota (`Need.skill_id`, `Need.quota`) — unchanged shape from Part 1.
2. Per-skill candidate queues, ranked via the existing `matching.rank_candidates`, one per unfulfilled `Need`. A multi-skill volunteer appears in multiple queues.
3. Batch/escalation dispatch continues per-skill as today (Section 4.10 batch sizing off that skill's *remaining* quota).
4. **New**: whenever a volunteer accepts (via whichever skill's alarm reached them), check their full skill set against every other still-unfulfilled `Need` on the same report. For each other need they also satisfy, credit them toward it too — decrement that need's remaining quota by one — without a separate alarm/dispatch for it.
5. A need is fulfilled when its remaining quota (after credits) reaches zero, same completion check as today, now credit-aware.

**Resolved**: `Assignment` keeps its existing `UniqueConstraint("report_id", "volunteer_id")` — one volunteer, one `Assignment` row per report, unchanged (this also avoids double-processing in `confirmation.resolve()`, which loops every `Assignment` on a report doing per-row side effects like bumping `completion_count` and sending notifications). Cross-skill credit is recorded as a new `Assignment.credited_skill_ids: list[int]` (JSON) column on that same single row — the skills of *other* needs this assignment also satisfies, beyond the one it was actually dispatched/alarmed for. `accepted_count(need_id)` counts an assignment toward a need when `assignment.need_id == need.id` OR `need.skill_id in assignment.credited_skill_ids`. `apply_experience()` bumps `verified_experience` for every credited skill, not just the primary one.

### Testing plan

- Unit test: a volunteer with 2 matching skills, accepting one alarm, decrements both needs' remaining quotas.
- Unit test: a report needing `P3K: 2, Evakuasi: 1` — batch sizes/escalation timing still follow Section 4.10 per skill.
- End-to-end (extends `test_flow.py`): full report → extraction → dispatch → accept → verify cross-credit → verify completion once all quotas exhausted.

## Non-goals (explicitly out of scope)

- A separate "collective/report-wide" headcount beyond the sum of per-skill quotas — considered and rejected during design (Option A chosen: no separate collective number, purely per-skill quotas with cross-crediting).
- Any `Skill` table columns beyond `id`/`name` (no `kelompok`/definition columns) — richer domain knowledge lives in the LLM system prompt as static text, not DB rows.
- A rule-based fallback for 12-skill selection — relies on manual reporter correction instead.

## Migration/rollout notes

- No manual SQL needed for either environment — see Part 1's model-change note.
- `simulation.py`'s demo/seed data must be updated in the same change, since `VolunteerSkill` becomes FK-based — old free-text skill names won't resolve against the new catalog.
- **Frontend impact**: the Flutter app currently displays `category`/`skill` strings from the API (`reports.py`, `volunteer.py` responses). Those response shapes change to `skill_id`/`skill_name`-based — the app-side rendering needs a matching update, tracked separately from this backend spec.
