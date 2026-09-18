"""Rule-based need identification (FR-4.1, FR-4.3, FR-4.5).

Maps the report text (+ the confirmed extraction) to need categories from the
``need_catalog`` config. Each category requires one skill and has a default
quota (Required Need); the reporter can adjust both category list and quotas
before submitting (FR-4.2).
"""
import re

# keyword patterns -> category. Matched against lower-cased text.
CATEGORY_RULES: dict[str, list[str]] = {
    "pemadaman_awal": [r"api", r"terbakar", r"kebakaran", r"asap", r"apar", r"padam", r"menjalar", r"merambat"],
    "evakuasi": [r"terjebak", r"terperangkap", r"evakuasi", r"lansia", r"anak", r"bayi", r"disabilitas",
                 r"tidak bisa keluar", r"mengungsi", r"warga panik", r"penghuni"],
    "medis": [r"luka", r"terluka", r"korban", r"sesak", r"pingsan", r"luka bakar", r"berdarah", r"p3k",
              r"ambulans", r"tidak sadar"],
    "logistik": [r"kehilangan", r"pengungsi", r"makanan", r"selimut", r"air bersih", r"pakaian",
                 r"tempat tinggal", r"tenda", r"logistik", r"hangus"],
    "akses": [r"gang sempit", r"jalan sempit", r"macet", r"tidak bisa masuk", r"sulit masuk", r"akses",
              r"terhalang", r"parkir", r"lalu lintas", r"kerumunan", r"menonton"],
    "psikososial": [r"trauma", r"menangis", r"histeris", r"syok", r"shock", r"panik"],
}

# Every residential fire gets initial fire suppression support.
ALWAYS_FOR_INCIDENT = {"kebakaran": ["pemadaman_awal"]}


def map_needs(text: str, incident_type: str, catalog: dict) -> list[dict]:
    """Return [{category, label, skill, quota, reason}] in catalog order."""
    lowered = (text or "").lower()
    hits: dict[str, str] = {}
    for category, patterns in CATEGORY_RULES.items():
        for p in patterns:
            m = re.search(rf"\b{p}\b", lowered)
            if m:
                hits.setdefault(category, m.group(0))
                break
    for category in ALWAYS_FOR_INCIDENT.get(incident_type, []):
        hits.setdefault(category, f"standar untuk {incident_type}")
    if not hits:  # nothing recognised: still ask for basic help instead of failing
        hits["evakuasi"] = "default"

    result = []
    for category, spec in catalog.items():
        if category in hits:
            result.append({
                "category": category,
                "label": spec["label"],
                "skill": spec["skill"],
                "quota": int(spec["quota"]),
                "reason": hits[category],
            })
    return result
