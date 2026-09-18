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

## Recommendations

1. **Before the demo**, re-run `tune_extraction.py` a couple more times against cases 5 and 10-16 specifically, since both the JSON-failure and the nondeterminism showed up on repeated runs — a fresh run right before presenting will tell you today's actual reliability, not last week's.
2. Consider bumping `max_tokens` in `_llm_extract` if JSON-generation failures (#1) recur often — cheap to try, no schema changes needed.
3. If Indonesian-only titles matter for the demo's polish, add one line to `SYSTEM_PROMPT_TEMPLATE` requiring `title` in Bahasa Indonesia regardless of input language (issue #3).
4. Keep `tune_extraction.py` around and keep adding real report text to `CASES` as you find edge cases in manual testing — it's the fastest way to get a reproducible before/after comparison when tweaking the prompt.
