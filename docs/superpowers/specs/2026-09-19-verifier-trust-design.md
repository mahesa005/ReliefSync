# Event Verification & Verifier Trust Score — Design

## Context

Two pieces of infrastructure already exist and are being reused here, not rebuilt:

- **Nearby sighting/awareness**: `dispatch.notify_nearby_users` already pushes a "nearby" notification ("Apakah Anda melihat kejadian ini? Ketuk untuk konfirmasi.") to users within their own configurable radius (`User.nearby_radius_km`, default 3km, up to 20km). Tapping it creates a `Sighting` row. Per the existing UI/UX spec, this is currently purely decorative — a count only, explicitly "tidak memengaruhi trust score."
- **Post-resolution accuracy feedback**: once a report resolves, every volunteer whose `Assignment.status == "selesai"` (they actually completed the task) is asked, via `POST /reports/{id}/accuracy`, whether the report's description matched what they found (`AccuracyFeedback.matches: bool`). This already powers the **reporter's** trust tier in `trust.py` (majority vote per report, across all their reports).

This spec adds a **separate** verifier trust score (per the existing "Verifikasi Bencana & Trust Score" doc's own Section 7: reporter accuracy and verifier accuracy are different behaviors and should not be merged into one score) — but the ground-truth mechanism it needs already exists in the second bullet above; it just needs one new field.

## Scope

Three pieces, delivered together since each depends on the last:
1. **Event verification** — upgrade the existing sighting tap into an explicit Yes/Not-sure choice.
2. **Ground truth capture** — extend the existing post-resolution feedback to also ask "was this real or a hoax," from the same people, at the same moment.
3. **Verifier trust score** — a point-accumulating score (not a ratio), computed the same way `trust.py` already computes reporter trust: read-time, from raw rows, no incrementally-maintained counters.

## Part 1: Event Verification

- The existing "nearby" notification's action changes from a single implicit "confirm" tap to two explicit choices: **Ya** / **Tidak yakin**.
- Tapping **Ya** creates a `Sighting` row — same as today, no model change needed here.
- Tapping **Tidak yakin** creates no row at all and has no effect on anything (matches the existing doc's principle: "tidak dapat memastikan tidak dihitung sebagai bukti bahwa kejadian tidak ada" — absence of confirmation is never treated as evidence against the report).
- The nearby-notification radius mechanism (`User.nearby_radius_km`) is reused as-is for now. The original "Verifikasi Bencana" doc specified a fixed 200m radius specifically for verification eligibility (tighter than general nearby-awareness, on the theory that "verifying" implies being close enough to actually see it) — **left as an open, deferred decision**, not resolved by this spec. Reusing the existing mechanism is the smaller change; introducing a separate fixed-200m eligibility check is a real option if the team decides plausibility of "did they actually see it" matters more than reusing existing infra.

## Part 2: Ground Truth Capture

`AccuracyFeedback` gains one new field, asked in the same prompt as the existing `matches` question, to the same population (completed-assignment volunteers), at the same time (after resolution):

```python
class AccuracyFeedback(Base):
    ...
    matches: Mapped[bool] = mapped_column(Boolean)
    verdict: Mapped[str] = mapped_column(String(10), default="valid")  # "valid" | "hoax"
```

`default="valid"` exists purely for backward compatibility with rows already in production before this column existed (same pattern as `Report.content_valid`'s default earlier this session) — new submissions always provide it explicitly; `AccuracyIn`'s `verdict: Literal["valid", "hoax"]` has no default, so the reporter-facing form always asks.

**Per-report ground truth** is computed exactly the way `trust.py` already computes reporter accuracy — majority vote, no new pattern:
```python
def report_verdict(db: Session, report_id: str) -> str | None:
    """None = no feedback yet, or nothing to conclude from -- callers must
    treat this as 'not settled', not as 'valid'."""
    votes = [f.verdict for f in db.scalars(select(AccuracyFeedback).where(AccuracyFeedback.report_id == report_id))]
    if not votes:
        return None
    hoax_votes = sum(1 for v in votes if v == "hoax")
    return "hoax" if hoax_votes * 2 > len(votes) else "valid"
```
Ties go to "valid" (benefit of the doubt — consistent with the existing `matches` majority-vote's own `>=` bias toward the positive outcome at exact ties). A report with zero feedback submitted is **not** "valid by default" for scoring purposes — it's unsettled, and verifiers who confirmed it are simply never scored for it (see Part 3).

## Part 3: Verifier Trust Score

**Explicitly not a ratio.** Every scored `Sighting` moves a running point total, computed at read time from raw rows — the same architectural pattern `trust.py` already uses (no incrementally-maintained counter column, no risk of drift between a stored counter and the underlying rows):

```python
BASELINE = 50
CORRECT_DELTA = 2
WRONG_DELTA = -3  # asymmetric: confirming a hoax costs more than confirming real gains

def verifier_score(db: Session, user_id: str) -> tuple[int, int]:
    """Returns (score, evaluated_count)."""
    sightings = db.scalars(select(Sighting).where(Sighting.user_id == user_id)).all()
    score = BASELINE
    evaluated = 0
    for s in sightings:
        verdict = report_verdict(db, s.report_id)
        if verdict is None:
            continue  # report not yet resolved / no feedback submitted -- skip, don't guess
        evaluated += 1
        score += CORRECT_DELTA if verdict == "valid" else WRONG_DELTA
    return max(0, min(100, score)), evaluated
```

**Tiers**, by score threshold once past the "Akun Baru" gate (same gating pattern as reporter trust — a minimum evaluated count before any tier judgment is rendered):

| Tier | Condition |
|---|---|
| Akun Baru | `evaluated_count < 3` |
| Rendah | score 0–25 |
| Cukup | score 26–50 |
| Baik | score 51–75 |
| Sangat Baik | score 76–100 |

Baseline (50) lands a brand-new-but-past-the-gate account in "Cukup" — neutral-until-proven, not automatically "good." Never displayed as a raw number to end users (same principle as FR-9.2 for reporter trust) — only the tier label.

## Non-goals (explicitly out of scope for this spec)

- Recency-weighting or decay of old verifications — a real future improvement, deliberately deferred as unnecessary complexity for now.
- A statistically-adjusted ratio (e.g. Wilson score interval) as an alternative to raw points — considered, rejected in favor of the simpler, more explainable additive model for a hackathon context.
- Changing the verification-eligibility radius from the existing configurable mechanism to a fixed 200m — flagged above as an open decision, not resolved here.
- Any interaction between verifier trust and reporter trust, or between verifier trust and matching/dispatch priority — they stay fully independent, per the existing doc's explicit "jangan digabung" principle.
- Retroactively backfilling verifier scores for `Sighting` rows that predate this feature — new field defaults handle schema compatibility; no historical backfill logic.

## Migration / rollout note

Same caveat as every other schema change this session: `AccuracyFeedback` already exists as a table in any previously-deployed database, so `Base.metadata.create_all()` will **not** add the new `verdict` column automatically. Before deploying, that column needs an `ALTER TABLE accuracy_feedback ADD COLUMN IF NOT EXISTS verdict VARCHAR(10) NOT NULL DEFAULT 'valid';` on any existing instance (same pattern used for `Report.content_valid` earlier).
