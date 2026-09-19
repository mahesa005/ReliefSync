# Spec vs. Implementation Alignment Report

**Date:** 2026-09-19
**Method:** Every claim below was checked directly against current code (file:line cited), not recalled from memory. No code was changed to produce this report.
**Documents reviewed:** User Story, FR & NFR (Revisi 3), Kejadian Darurat, Verifikasi Bencana & Trust Score, Priority Level/Matching Algorithm, Skill Relawan, UI/UX Spec (dated Sep 18, 2026 — the newest of the set).

## TL;DR

Most of the FR/NFR doc's *structure* (hard filter → score → fairness → tie-break → batch escalation → collective confirmation) is implemented essentially 1:1, including exact numeric formulas verified by tests. The real divergences cluster in three places:

1. **Two documents disagree with each other** on the Priority Score weights and the Competency formula — the code picked one set, and it's worth confirming that was intentional.
2. **Section 4 (AI extraction)** evolved substantially *this session* — the FR/NFR doc's evidence-anchoring requirement (FR-3.2/3.3) was deliberately dropped, and Section 4's "rule-based" need mapping (FR-4.1) was replaced entirely by direct LLM skill selection. This is the biggest structural departure from the written spec, done for good reasons, but it means FR-3.2/3.3/4.1 as literally written no longer describe the system.
3. **The "Verifikasi Bencana & Trust Score" doc's elaborate verifier-trust system was never built** — and the *later* UI/UX spec doc explicitly describes a simpler version, suggesting this was a deliberate team decision to simplify, not an oversight. Worth confirming that's actually what happened rather than just "ran out of time."

---

## 1. Priority Score / Matching Algorithm — ⚠️ Two source documents disagree; code matches neither exactly

The **Priority Level doc** you just pasted specifies:
- `Priority = 0.30E + 0.10VE + 0.45D + 0.08CH + 0.07SD`
- `Competency = 0.75E + 0.25VE`

The **current code** (`backend/app/core/app_config.py:15-16`):
```python
"score_weights": {"evidence": 0.30, "verified_experience": 0.10, "distance": 0.40,
                  "completion": 0.10, "similar_disaster": 0.10},
```
and (`backend/app/services/matching.py:76`):
```python
competency = 0.60 * e + 0.40 * ve  # C = 0.60E + 0.40VE
```

Evidence (30%) and Verified Experience (10%) match. **Distance/Completion/Similar-Disaster (40/10/10 in code vs. 45/8/7 in the doc) and the Competency split (60/40 in code vs. 75/25 in the doc) do not.** The code's own docstring cites "context doc Section 4" as its source — meaning it was built against a different/earlier version of this spec than the one just pasted. I don't know which numbers are the intended final ones; this needs your call, not mine.

**What does match exactly** (verified by an automated test against the doc's own 100-row reference table, `backend/tests/test_rules.py::test_quorum_matches_reference_table`):
- The collective-confirmation quorum formula (Section 12/12.1 of this doc, FR-7.4 in the FR/NFR doc) — `T(N)` for every N from 1–100, exact match.
- Batch escalation sizing (Section 11: B1=Required Need, B2=Remaining Need, B3+=2^k×Remaining) — `matching.py:124-132`, exact match, also test-covered.
- Hard filter (Availability ON, SkillMatch, Distance ≤ 5km) — exact match.
- Fairness near-tie threshold (0.02) and tie-break order (Distance → Competency → Selection Count → fallback) — exact match.
- Evidence scores (self-declared 0.70, certified 1.00) — exact match.
- Diminishing-return experience cap formula and cap=10 — exact match.

## 2. FR & NFR (Revisi 3) — mostly aligned; the AI/needs sections evolved this session

| Section | Status | Note |
|---|---|---|
| FR-1.x (accounts) | ✅ Aligned | Single `User` + optional `VolunteerProfile`, not two account types — exactly the "peran berlapis" model the doc calls for. |
| FR-2.x (reporting) | ✅ Aligned | FR-2.2's "speech-to-text" is clarified by the later UI/UX doc as OS keyboard dictation, not a custom feature — code matches that clarified intent. |
| **FR-3.2 / FR-3.3** (evidence cuplikan + "belum diketahui" for unsupported fields) | ❌ **Deliberately removed** | This was the OLD 4-field schema's `enforce_evidence()` mechanism. This session's redesign (title/description via one Groq call) dropped verbatim-evidence enforcement entirely — `title`/`description` are now LLM-authored summaries, not extracted-with-proof spans. This is a real, literal departure from FR-3.2/3.3 as written, done deliberately (documented in `docs/superpowers/specs/2026-09-18-skill-extraction-and-dispatch-design.md`), not an oversight. |
| **FR-4.1** ("sistem memetakan laporan menjadi kategori kebutuhan berdasarkan aturan/rule-based") | ❌ **Superseded** | The regex/rule-based category mapper (`needs.py`) was deleted this session and replaced with direct LLM skill+quota selection against a 12-skill catalog. The *outcome* (needs get identified) still holds; the *mechanism* named in FR-4.1 ("rule-based") no longer exists except as the no-AI-available fallback path. |
| FR-4.3 ("jumlah relawan... tuning tim", listed as an Open Item) | ✅ Resolved, differently than implied | Not manually tuned per-category — the LLM estimates it per-skill, with `victim_count` extracted separately and used as a hard floor in code (`extraction.py`'s `_sanitize_needs`). More sophisticated than the doc's "tim akan tuning angka" framing anticipated. |
| FR-5.x (matching/notification) | ✅ Strongly aligned | See Section 1 above for the one numeric caveat. |
| FR-6.x/7.x (accept/reject, collective confirmation) | ✅ Aligned, test-verified | Quorum table exact match; AFK exclusion, 24h auto-resolve, reject-doesn't-block-others all present. |
| FR-8.x (status monitoring) | ✅ Mostly aligned | FR-8.6 itself is truncated in your source text ("...menjadi 'Nearby/On location' atau" cuts off) so I can't check against the full intended requirement; the 2-state `travel_status` (`otw`/`sampai`) is what exists. |
| FR-9.x (trust) | ✅ Exact match | `trust.py`'s three tiers are word-for-word "Akun baru / Riwayat akurasi rendah / Riwayat baik" (FR-9.2). |
| FR-10.x (agency contact) | ✅ Aligned | Curated list (`agencies.py`), `tel:` URI Call button, no auto-official-status on call — matches FR-10.1-10.4 exactly. |
| NFR-13 (configurable durations) | ✅ Confirmed | Everything under Section 1's weights/timings lives in the `app_config` table, editable via `PUT /config/{key}` without a redeploy. |
| NFR-14/15 (masking, restricted views) | ✅ Confirmed | `mask_phone()` applied everywhere; `report_view`'s `involved` check limits what uninvolved viewers see. |

## 3. Kejadian Darurat (6 incident categories) — ❌ category list has drifted

The doc specifies exactly 6 categories: **Kebakaran, Banjir, Tanah longsor, Gempa bumi, Kecelakaan, Bangunan runtuh.**

Current code (`backend/app/services/extraction.py:85-91`, `INCIDENT_TYPES`):
```
kebakaran, banjir, longsor, bangunan_roboh, kecelakaan, akses_terputus, lainnya
```

**"Gempa bumi" is missing entirely** — not present anywhere in `extraction.py` (confirmed via direct search, zero matches for "gempa"). In its place, the code has **`akses_terputus`** ("pohon tumbang, jalan terputus, terisolasi" — not in the doc's 6 categories at all) and a catch-all **`lainnya`** for anything that doesn't fit. This looks like a deliberate later expansion (`akses_terputus`, `lainnya`) that happened to drop earthquake along the way — worth confirming whether that's intentional or a genuine gap, since "Gempa bumi" was explicitly called out as category #4 in a demo-scenario-relevant way (Indonesia).

The doc's core *principle* — "kategori cukup luas, deskripsi wajib menentukan kebutuhan sebenarnya, bukan kategori itu sendiri" — is well aligned: the Groq extraction pipeline derives skills from free-text description, never from `incident_type` directly, matching Section 4's stated alur exactly.

## 4. Verifikasi Bencana & Trust Score — ✅ now implemented (updated after this branch)

**Update (this branch, 2026-09-19):** the point-based Verifier Trust Score described by this doc's Section 7 principle — reporter trust and verifier trust are tracked independently — is now implemented, in `backend/app/services/verifier_trust.py`. It scores each user's `Sighting` confirmations against the settled ground-truth verdict of the report (`AccuracyFeedback.verdict`, majority vote), producing the same five-tier ladder this doc names (Akun Baru / Rendah / Cukup / Baik / Sangat Baik). It's exposed on `GET /me` as `verifier_trust`, and wherever reporter trust already appears elsewhere in API responses as `reporter_verifier_trust`. Full design rationale (including why it does *not* use a fixed 200m confirmation radius — nearby notifications still use each user's own configurable radius, default 3km up to 20km, `dispatch.py:179`) is in `docs/superpowers/specs/2026-09-19-verifier-trust-design.md`. The paragraphs below reflect the state of the codebase *before* this branch and are kept for history.

This doc describes a full **verifier trust score system**: people within a fixed 200m radius can confirm a sighting, and their confirmation accuracy (checked once an incident's outcome is known) earns them their own trust tier — Akun Baru / Rendah / Cukup / Baik / Sangat Baik — separate from reporter trust.

**(Historical, pre-this-branch) None of that was implemented at the time this report was written.** Current code had a `Sighting` model (`backend/app/db/models.py`) that was a bare per-user boolean ("saya melihat kejadian ini") with a count, and `trust.py` only computed *reporter* trust from post-resolution accuracy feedback — there was no verifier-side trust tracking, no accuracy-checked verifier score, and no fixed 200m radius.

This wasn't necessarily a gap to fix, though — the newer UI/UX spec doc (dated the same day) appeared to contradict this doc, stating in its own words: *"Konfirmasi ini murni tampilan... tidak memengaruhi trust score; trust score tetap murni dari hasil konfirmasi pasca-tugas (FR-7.3, dikerjakan tim lain)."* That looked like a deliberate simplification decision at the time — but this branch shows the elaborate version was in fact still built, just later, as a separately-scoped feature (see the Update above).

## 5. Skill Relawan — ✅ fully aligned

This is the exact document used to build the current 12-skill catalog (`backend/app/services/skills.py`'s `SEED_SKILLS`) earlier this session — names, count, and order all match. The domain rules (no skill inheritance, swimming conditional on high water, general tasks excluded, out-of-scope actions like technical rescue never assigned) are encoded directly in `extraction.py`'s `DOMAIN_RULES` and verified with real Groq test cases (`docs/extraction-tuning-report.md`).

## 6. UI/UX Spec — mostly current, but Section 5 describes the OLD schema

This is dated the same day as this document and is the newest of the set, but **Section 5 ("Alur lapor bencana") still describes the pre-redesign extraction schema**: *"satu kali panggilan LLM → mengekstrak jenis_kejadian, kondisi_akses, kebutuhan_dinyatakan."* Those exact three field names were removed from the codebase this session, replaced by `title`/`description`/`needs`. This section of the UI/UX doc needs updating to match — it's now describing a schema that no longer exists in the backend, and the Flutter screens (`extraction_confirm_screen.dart`) have already been updated to the new shape independently.

One more worth flagging for double-checking, not confirmed either way: Section 11 states *"popup periodik... SATU tombol 'Sudah teratasi' — TIDAK ada tombol 'Belum'/vote negatif."* The backend's `confirmation.vote(db, report, user, done: bool, ...)` function does accept an explicit `done=False` path, and it's exercised in `test_full_dispatch_flow`. That's not necessarily a contradiction — the backend being more permissive than what the UI exposes is normal — but worth confirming the Flutter popup genuinely never renders a "Belum" affordance anywhere, since I didn't check every screen.

Section 12's "masih perlu diselaraskan tim" open items are now resolved, just not to the options the doc itself listed:
- "Capacitor vs React Native" → resolved to neither — the actual stack is **Flutter**, a third option the open item didn't even list.
- "Socket vs polling" → resolved to **polling** (3-6s, per README), consistent with NFR-3's "tanpa server WebSocket."
- "Statistik profile relawan: MVP atau stretch?" → built (`volunteer_stats` in `me.py`).
- "Trust score sedang dikerjakan terpisah" → built, the simple 3-tier reporter-only version (Section 4 above), not the elaborate verifier-trust version from the other doc.

## 7. Built this session, not described in any of these documents

- **Groq** as the specific LLM provider (docs say "AI"/"LLM" generically; started on Anthropic Claude earlier this project, switched to Groq this session).
- **Content-validity guardrail** (`valid`/`invalid_reason` fields) — rejects gibberish/spam reports before they reach volunteers. Not anticipated by any doc; came out of manual testing this session.
- **`victim_count` extraction + deterministic quota floor** — a concrete resolution to FR-4.3's open item, informed by the METHANE emergency-services reporting framework (researched this session), not something any of these docs specify.
- **Cross-skill credit dispatch** — one volunteer's acceptance can satisfy multiple needs on the same report if their skills match, without a separate alarm. This extends the Bantuan Utama/Tambahan model without contradicting it, but isn't mentioned anywhere in the FR/NFR or Priority Score docs — it's a new mechanism.

## Open questions for you / the team, not something I resolved

1. Which Priority Score weights are actually final — this doc's 45/8/7 + 75/25, or the code's current 40/10/10 + 60/40?
2. Was dropping "Gempa bumi" from the incident category list intentional, given the demo scenario context (Indonesia)?
3. Is the elaborate Verifier Trust Score doc formally superseded by the UI/UX spec's simpler version, or still "to be built"?
4. Does the UI/UX spec's Section 5 need a documentation update to reflect the new title/description/needs schema, or is that already tracked elsewhere?
