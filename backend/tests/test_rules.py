"""Quorum table, need mapping and extraction fallback."""
import asyncio

import pytest

from app.core.config import get_settings
from app.services import extraction
from app.services.confirmation import threshold_proportional, threshold_simple

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


def test_rule_based_extraction_has_real_evidence():
    fields, itype = extraction.rule_based_extract(REPORT)
    assert itype == "kebakaran"
    assert "Gang Mawar" in fields["lokasi_disebutkan"]["value"]
    assert "sempit" in fields["kondisi_akses"]["evidence"].lower()
    for f in fields.values():
        assert f["evidence"] is None or f["evidence"] in REPORT


def test_fabricated_evidence_becomes_unknown():
    fields = {name: {"value": "x", "evidence": "tidak ada di teks", "confidence": 0.9} for name in extraction.FIELDS}
    fields["jenis_kejadian"] = {"value": "kebakaran", "evidence": "Kebakaran rumah", "confidence": 0.9}
    out = extraction.enforce_evidence(fields, REPORT)
    assert out["jenis_kejadian"]["value"] == "kebakaran"
    assert out["kondisi_akses"] == {"value": extraction.UNKNOWN, "evidence": None, "confidence": 0.0}


def test_no_api_key_uses_rules():
    result = asyncio.run(extraction.extract(REPORT))
    assert result.source == "rule"


def test_llm_timeout_falls_back(monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "groq_api_key", "sk-test")
    monkeypatch.setattr(settings, "llm_timeout_seconds", 0.2)

    async def slow(_text):
        await asyncio.sleep(5)

    monkeypatch.setattr(extraction, "_llm_extract", slow)
    result = asyncio.run(extraction.extract(REPORT))
    assert result.source == "rule"
    assert "batas waktu" in result.note
    assert result.elapsed_ms < 2000


def test_llm_error_falls_back(monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "groq_api_key", "sk-test")

    async def boom(_text):
        raise RuntimeError("503")

    monkeypatch.setattr(extraction, "_llm_extract", boom)
    result = asyncio.run(extraction.extract(REPORT))
    assert result.source == "rule"


@pytest.mark.parametrize("phone,masked", [("081234567890", "0812****7890"), ("0812345678", "0812**5678")])
def test_mask_phone(phone, masked):
    from app.core.security import mask_phone
    assert mask_phone(phone) == masked
