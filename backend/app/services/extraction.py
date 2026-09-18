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
MAX_QUOTA = 50

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
        out.append({"skill_id": skill_id, "quota": max(1, min(MAX_QUOTA, int(n["quota"])))})
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
