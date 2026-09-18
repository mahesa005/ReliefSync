# Extraction Prompt Tuning Report

**Date:** 2026-09-18
**Model tested:** `openai/gpt-oss-20b` (Groq)
**Tool:** `backend/scripts/tune_extraction.py` (manual harness, not part of the automated test suite)
**Scope:** 16 hand-picked report texts, each targeting one specific guardrail written into `extraction.py`'s `DOMAIN_RULES`/system prompt, run twice (first pass without the content-validity guardrail, second pass with it added).

## Summary

| Guardrail | Result |
|---|---|
| No skill inheritance (P3K ≠ CPR/AED/bidai) | ✅ Holds |
| Swimming (`Berenang`) only under high-water context | ✅ Holds (see nondeterminism note below) |
| General/non-technical tasks excluded from `needs` | ✅ Holds |
| No fabrication under vague/low-signal input | ✅ Holds |
| Out-of-catalog skills never invented | ✅ Holds |
| **New: content-validity guardrail** (gibberish/spam rejection) | ✅ Holds, zero false positives |
| Skill-matching consistency (does it ever pick nothing when it should pick something) | ✅ 3/3 targeted cases picked correctly |
| `MAX_QUOTA` clamp (50) | ⚠️ Not exercised — model self-limited below 50 both times it was tried |
| JSON-generation reliability | ⚠️ One real failure — see below |
| Output language consistency | ⚠️ One inconsistency — see below |
| Run-to-run determinism at `temperature=0` | ⚠️ Not fully deterministic — see below |

## What was added this session: the content-validity guardrail

`ExtractionResult` gained `valid: bool` + `invalid_reason: str | None`, extended into the *same* Groq call (no extra latency/cost). The prompt instructs `valid=false` **only** for text that isn't coherent human language or doesn't describe any real situation (gibberish, keyboard mashing, spam/ads) — explicitly **not** based on how vague or short the report is. `Report.content_valid` persists the verdict; `confirm_report` now returns 422 until the reporter rewrites a flagged report. `_sanitize_needs` is skipped entirely (needs forced to `[]`) when invalid, regardless of what the model put in its own `needs` field — same "never trust the LLM" principle already used for `skill_id` sanitization.

**Test results (cases 11-13):**

| Case | Input | Result |
|---|---|---|
| 11 | Keyboard mash (`asdkfj alskdjf qwoeiru...`) | `valid=False`, reason: "Teks tidak dapat dipahami" ✅ |
| 12 | Repeated character spam (`aaaa...`) | `valid=False`, reason: "Teks tidak bermakna" ✅ |
| 13 | Coherent but off-topic ad ("Beli baju murah...") | `valid=False`, reason: "Spam/iklan" ✅ |

Critically, **every legitimate case — including the deliberately vague one (#7, "Ada kejadian di kampung sebelah, tolong dibantu")** — stayed `valid=True`. Zero false positives observed across the full 16-case run. This is the single most important thing to keep re-testing before the demo: a false-positive "invalid" verdict on a real report would block a real reporter from getting help.

## Skill-matching consistency (the "sometimes picks no skill" concern)

Three cases were built specifically to stress-test whether the model reliably picks *a* skill when one clearly applies:

| Case | Input | Result |
|---|---|---|
| 14 | Plain single-victim motor accident, injured, needs first aid | → `P3K` quota 1 ✅ |
| 15 | Immobile elderly person needs carrying down stairs during a fire | → `Teknik memindahkan korban` quota 1 ✅ |
| 16 | Reporter explicitly names the skill needed ("butuh orang yang bisa menggunakan APAR") | → `Penggunaan APAR` quota 1 ✅ |

All three picked correctly. The cases in the original 10 that returned **empty** `needs` (4, 6, 7) were all correctly empty — none of them described a situation needing a catalog skill (shallow flood/logistics-only, sembako distribution, or a genuinely vague one-liner). No case observed in this session showed the model failing to pick a skill when one was clearly warranted. If you're still seeing empty-needs cases you believe are wrong, the most useful next step is to add the *exact* report text that triggered it as a new case in `tune_extraction.py` so it's reproducible.

## Issues found (not blocking, but worth knowing before the demo)

### 1. Occasional Groq-side JSON-generation failure (real, caught safely)
Case 5 (swimming/high-water report) returned an actual `400` from Groq itself:
```
{"error":{"message":"Failed to validate JSON. Please adjust your prompt. See 'failed_generation' for more details.","...":"json_validate_failed","failed_generation":""}}
```
`failed_generation` was empty — the model produced nothing usable. This is a `gpt-oss-20b` reliability issue (likely related to its internal "reasoning" token budget being consumed before it emits the final JSON — see the earlier session note about `reasoning_tokens` eating into `max_tokens`), not a bug in our code. **The fallback caught it correctly** — the app degraded to the rule-based path exactly as designed (NFR-9/10), so no user-facing crash. If this happens often enough to be annoying during the demo, two options: raise `max_tokens` above 1024 to give the model more room to finish reasoning before the JSON, or switch to a non-reasoning model.

### 2. Run-to-run nondeterminism at `temperature=0`
Case 5, run on two separate occasions with identical input, produced different `needs`: once `P3K + Penggunaan tandu + Teknik memindahkan korban + Berenang`, once `Berenang` alone (and once it flat-out failed to generate valid JSON, per issue #1 above). `temperature=0` reduces but does not eliminate variance on Groq's `on_demand` tier. Don't assume identical input always produces identical output during a live demo.

### 3. Mixed-language input can produce a mixed-language title
Case 8 (English + Indonesian in the same report) came back with `title: "Fire at Neighbor's House"` (English) but `description` correctly in Indonesian. The prompt only explicitly requires Indonesian for `description`, not `title`. If guaranteed-Indonesian titles matter, add the same requirement to the `title` field's instruction.

### 4. `MAX_QUOTA` clamp untested in practice
Case 10 (100+ victims) produced `P3K quota=10` and, in an earlier run, `P3K=20, CPR/RJP=10, Penanganan perdarahan=10` — always self-limited well under the 50 clamp. The clamp code path (`_sanitize_needs`'s `min(MAX_QUOTA, ...)`) is still in place as a backstop but has not been observed actually triggering. Not a concern — just noting the safety net remains unverified by these particular inputs.

## Follow-up: quota didn't scale with stated victim count (found via manual testing, fixed)

After this report was first written, manual testing surfaced a real case: a report stating **5 people** in danger of falling from a roof came back with `quota=1` for the relevant skills — the estimate didn't account for the number of people needing simultaneous help at all.

**Root cause 1 (prompt gap):** `DOMAIN_RULES` told the model to "estimate volunteers per skill" but never said the estimate should scale with how many people need help at once. Fixed by adding rule 6: quota must account for the stated number of victims (e.g. "5 orang harus dievakuasi" → quota ≈ 5, not 1), while explicitly not requiring this for single-victim cases.

**Root cause 2 (uncovered while fixing #1):** immediately after lengthening the prompt, the same case started failing with a genuinely different Groq error: `"max completion tokens reached before generating a valid document"` — this is the *exact* mechanism issue #1 above speculated about. The reasoning model was spending its entire `max_tokens: 1024` budget on internal reasoning and running out before it could emit the JSON. Fixed by raising `max_tokens` to `2048`.

**Verified after both fixes**, re-run three times:
| Case | quota result |
|---|---|
| Baseline single-victim ("ada yang pingsan...") | `P3K quota=1` — unchanged, no over-inflation |
| Single-victim accident | `P3K quota=1` — unchanged |
| 5-person roof rescue (run 1) | `Penggunaan tandu=5, Teknik memindahkan korban=5` |
| 5-person roof rescue (run 2, independent) | `Penggunaan tandu=5, Teknik memindahkan korban=5` — consistent |

Both fixes are live in `extraction.py` (`DOMAIN_RULES` rule 6, `max_tokens=2048`) and covered by a new case (17) in `tune_extraction.py`. This also directly addresses issue #1's speculation from earlier in this report and issue #2's nondeterminism is worth re-checking now that `max_tokens` is higher — a tighter token budget forcing the model to cut reasoning short may have been contributing to inconsistent output, not just occasional outright failure.

### Upgrade: `victim_count` as an explicit field (METHANE-informed)

Researched how emergency services structure incident reports for exactly this kind of situational assessment: the UK's **METHANE** mnemonic (evolved from CHALET → ETHANE, now standard under JESIP) requires **Numbers** (casualty count), **Hazards**, and **Access** as first-class fields extracted from any incident report, not left buried in free text. Applied the "Numbers" piece here (Hazards/Access structuring was scoped out for now — see the design conversation for the fuller option that was considered and deferred):

- `ExtractionResult`/`Extraction` gained `victim_count: int | None`.
- `_sanitize_needs` now takes `victim_count` and applies it as a **hard floor** on every selected skill's quota, computed in Python — not asked of the model as a one-shot judgment call. This deliberately over-provisions skills that don't scale 1:1 with victims (e.g. one P3K volunteer can treat several people) — the safe failure mode for a disaster-response app.

**Verified with real Groq calls:**
| Case | `victim_count` | Resulting quota |
|---|---|---|
| Roof rescue (5 people stated) | `5` | `P3K=5, Penggunaan tandu=5, Teknik memindahkan korban=5` — all three skills the model picked this run, all correctly floored |
| Baseline single-victim | `1` | `P3K=1` — no over-inflation |

Note the roof-rescue case picked a *different* combination of skills than earlier runs (previously sometimes just `Berenang` alone, sometimes 4 skills) — the nondeterminism in *which* skills get selected (issue #2) is unchanged, but now it no longer matters for quota correctness: whichever skills it picks, they're all floored to the real headcount.

## Recommendations

1. **Before the demo**, re-run `tune_extraction.py` a couple more times against cases 5 and 10-16 specifically, since both the JSON-failure and the nondeterminism showed up on repeated runs — a fresh run right before presenting will tell you today's actual reliability, not last week's.
2. ~~Consider bumping `max_tokens`~~ — done (see follow-up section above): raised to 2048, resolved the JSON-truncation failure in the cases tested since. Keep an eye out for recurrence.
3. If Indonesian-only titles matter for the demo's polish, add one line to `SYSTEM_PROMPT_TEMPLATE` requiring `title` in Bahasa Indonesia regardless of input language (issue #3).
4. Keep `tune_extraction.py` around and keep adding real report text to `CASES` as you find edge cases in manual testing — it's the fastest way to get a reproducible before/after comparison when tweaking the prompt.
