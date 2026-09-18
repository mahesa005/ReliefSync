"""AI extraction of a free-text report (FR-3.1 - FR-3.3, NFR-1, NFR-9, NFR-10).

One Claude call extracts ``jenis_kejadian``, ``lokasi_disebutkan``,
``kondisi_akses`` and ``kebutuhan_dinyatakan``, each with a verbatim evidence
snippet and a confidence score. Location coordinates are NOT extracted here --
they are a separate field of the report.

Reliability rules:
  * hard timeout (default 5 s); on timeout / error / refusal / no API key the
    rule-based extractor runs instead, so submission is never blocked;
  * every evidence snippet must literally occur in the report text, otherwise the
    field is reset to "belum diketahui" (FR-3.3: nothing is made up).
"""
import asyncio
import json
import logging
import re
import time
from dataclasses import dataclass

from pydantic import BaseModel, Field

from ..core.config import get_settings

log = logging.getLogger("reliefsync.extraction")

UNKNOWN = "belum diketahui"
FIELDS = ["jenis_kejadian", "lokasi_disebutkan", "kondisi_akses", "kebutuhan_dinyatakan"]
FIELD_LABELS = {
    "jenis_kejadian": "Jenis kejadian",
    "lokasi_disebutkan": "Lokasi disebutkan",
    "kondisi_akses": "Kondisi akses",
    "kebutuhan_dinyatakan": "Kebutuhan dinyatakan",
}


class ExtractedField(BaseModel):
    value: str = Field(description='Nilai ringkas dalam Bahasa Indonesia, atau "belum diketahui".')
    evidence: str | None = Field(description="Cuplikan kata-per-kata dari laporan yang mendukung nilai, atau null.")
    confidence: float = Field(description="Keyakinan 0.0 - 1.0.")


class ExtractionResult(BaseModel):
    jenis_kejadian: ExtractedField
    lokasi_disebutkan: ExtractedField
    kondisi_akses: ExtractedField
    kebutuhan_dinyatakan: ExtractedField


@dataclass
class Extraction:
    fields: dict[str, dict]  # field -> {value, evidence, confidence}
    source: str  # llm | rule
    elapsed_ms: int
    note: str | None = None
    incident_type: str = "kebakaran"


SYSTEM_PROMPT = """Kamu adalah pengekstrak data untuk aplikasi tanggap bencana ReliefSync.
Dari laporan warga, isi empat field:
- jenis_kejadian: jenis bencana/kejadian (mis. "kebakaran permukiman").
- lokasi_disebutkan: lokasi yang DISEBUT di teks (nama jalan, gang, RT/RW, patokan). Bukan koordinat.
- kondisi_akses: kondisi akses menuju lokasi (mis. "gang sempit, mobil damkar sulit masuk").
- kebutuhan_dinyatakan: bantuan yang dinyatakan/tersirat dibutuhkan (mis. "evakuasi lansia, P3K").

Aturan wajib:
1. "evidence" HARUS salinan persis (kata per kata) dari teks laporan. Jangan parafrase.
2. Jika tidak ada bukti di teks untuk suatu field, isi value "belum diketahui", evidence null, confidence 0.
3. Jangan mengarang informasi yang tidak ada di teks.
4. Tulis value dalam Bahasa Indonesia yang ringkas."""


# ---------------------------------------------------------------------------
# Rule-based extractor (fallback, NFR-9/10)
# ---------------------------------------------------------------------------
_INCIDENT_PATTERNS = [
    ("kebakaran", "kebakaran permukiman",
     r"kebakaran|terbakar|api|asap|korslet|korsleting|hangus|menyala|meledak"),
    ("banjir", "banjir", r"banjir|genangan|air naik|terendam"),
    ("longsor", "tanah longsor", r"longsor"),
    ("gempa", "gempa bumi", r"gempa"),
]
_LOCATION_PATTERN = (r"(?:\b(?:jl\.?|jalan|gang|gg\.?|rt\.?\s?\d+|rw\.?\s?\d+|kelurahan|kel\.|kecamatan|kec\.|"
                     r"komplek|kompleks|perumahan|blok|dekat|depan|belakang|samping|sebelah)\b)")
_ACCESS_PATTERN = (r"gang sempit|jalan sempit|sempit|tidak bisa masuk|sulit masuk|susah masuk|macet|"
                   r"terhalang|tertutup|buntu|akses|mobil (?:damkar|pemadam) (?:tidak|sulit|susah)|licin")
_NEED_PATTERN = (r"butuh|perlu|tolong|bantu|terjebak|terperangkap|luka|korban|evakuasi|lansia|anak|"
                 r"pingsan|sesak|air|ember|apar|selimut|makanan")


def _sentences(text: str) -> list[str]:
    parts = re.split(r"(?<=[.!?\n])\s+", text.strip())
    return [p.strip() for p in parts if p.strip()]


def _sentence_with(text: str, pattern: str) -> tuple[str, str] | None:
    """(matched keyword, sentence containing it) for the first match."""
    for s in _sentences(text):
        m = re.search(pattern, s, flags=re.IGNORECASE)
        if m:
            return m.group(0), s
    return None


def _clip(s: str, limit: int = 160) -> str:
    return s if len(s) <= limit else s[:limit].rsplit(" ", 1)[0]


def rule_based_extract(text: str) -> tuple[dict[str, dict], str]:
    fields = {f: {"value": UNKNOWN, "evidence": None, "confidence": 0.0} for f in FIELDS}
    incident_type = "kebakaran"

    for itype, label, pattern in _INCIDENT_PATTERNS:
        hit = _sentence_with(text, pattern)
        if hit:
            incident_type = itype
            fields["jenis_kejadian"] = {"value": label, "evidence": hit[0], "confidence": 0.6}
            break

    hit = _sentence_with(text, _LOCATION_PATTERN)
    if hit:
        snippet = _clip(hit[1])
        fields["lokasi_disebutkan"] = {"value": snippet, "evidence": snippet, "confidence": 0.5}

    hit = _sentence_with(text, _ACCESS_PATTERN)
    if hit:
        snippet = _clip(hit[1])
        fields["kondisi_akses"] = {"value": snippet, "evidence": snippet, "confidence": 0.5}

    needs = []
    evidence = None
    for s in _sentences(text):
        found = re.findall(_NEED_PATTERN, s, flags=re.IGNORECASE)
        if found:
            needs.extend(w.lower() for w in found)
            evidence = evidence or _clip(s)
    if needs:
        uniq = list(dict.fromkeys(needs))
        fields["kebutuhan_dinyatakan"] = {"value": ", ".join(uniq), "evidence": evidence, "confidence": 0.5}
    return fields, incident_type


# ---------------------------------------------------------------------------
# LLM extractor
# ---------------------------------------------------------------------------
def _normalize(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip().lower()


def enforce_evidence(fields: dict[str, dict], text: str) -> dict[str, dict]:
    """FR-3.3: a field whose evidence is not literally in the text becomes unknown."""
    norm_text = _normalize(text)
    out = {}
    for name in FIELDS:
        f = fields.get(name) or {}
        value = (f.get("value") or "").strip()
        evidence = (f.get("evidence") or "").strip()
        if not value or value.lower() == UNKNOWN or not evidence or _normalize(evidence) not in norm_text:
            out[name] = {"value": UNKNOWN, "evidence": None, "confidence": 0.0}
        else:
            conf = float(f.get("confidence") or 0.0)
            out[name] = {"value": value, "evidence": evidence, "confidence": round(min(1.0, max(0.0, conf)), 2)}
    return out


def _incident_type_from(value: str) -> str:
    for itype, _, pattern in _INCIDENT_PATTERNS:
        if re.search(pattern, value or "", flags=re.IGNORECASE):
            return itype
    return "kebakaran"


GROQ_API_URL = "https://api.groq.com/openai/v1/chat/completions"


async def _llm_extract(text: str) -> dict[str, dict]:
    import httpx  # already a project dependency

    s = get_settings()
    schema_prompt = (
        SYSTEM_PROMPT
        + "\n\nBalas HANYA dengan JSON valid (tanpa teks lain, tanpa markdown) sesuai skema ini:\n"
        + json.dumps(ExtractionResult.model_json_schema(), ensure_ascii=False)
    )
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
                    {"role": "system", "content": schema_prompt},
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


async def extract(text: str) -> Extraction:
    start = time.perf_counter()
    s = get_settings()
    note = None
    if s.groq_api_key and text.strip():
        try:
            raw = await asyncio.wait_for(_llm_extract(text), timeout=s.llm_timeout_seconds + 0.5)
            fields = enforce_evidence(raw, text)
            return Extraction(
                fields=fields,
                source="llm",
                elapsed_ms=int((time.perf_counter() - start) * 1000),
                incident_type=_incident_type_from(fields["jenis_kejadian"]["value"]),
            )
        except (TimeoutError, asyncio.TimeoutError):
            note = "AI tidak merespons dalam batas waktu; memakai ekstraksi berbasis aturan."
            log.warning("LLM extraction timed out; using rule-based fallback")
        except Exception as exc:  # noqa: BLE001 -- any AI failure must fall back (NFR-10)
            note = "AI tidak tersedia; memakai ekstraksi berbasis aturan."
            log.warning("LLM extraction failed (%s); using rule-based fallback", exc)
    elif not s.groq_api_key:
        note = "Ekstraksi berbasis aturan (AI tidak dikonfigurasi)."

    try:
        fields, incident_type = rule_based_extract(text)
    except Exception:  # noqa: BLE001
        log.exception("rule-based extraction failed")
        fields = {f: {"value": UNKNOWN, "evidence": None, "confidence": 0.0} for f in FIELDS}
        incident_type = "kebakaran"
    return Extraction(
        fields=enforce_evidence(fields, text),
        source="rule",
        elapsed_ms=int((time.perf_counter() - start) * 1000),
        note=note,
        incident_type=incident_type,
    )
