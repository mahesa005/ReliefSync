"""Official agency suggestions (FR-10.1 - FR-10.3, Open Item #4).

A small curated list for the single MVP scenario (residential fire), with a
Jakarta-specific entry. The app calls the number through a native ``tel:`` URI
(NFR-8); pressing Call never marks the incident as officially handled (FR-10.4).
"""
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db.models import Agency, Report
from .geo import region_of

SEED_AGENCIES = [
    # name, phone, description, incident types ([] = all), region, urgency rank
    ("Jakarta Siaga 112", "112", "Layanan darurat terpadu DKI Jakarta (damkar, ambulans, polisi).",
     [], "jakarta", 1),
    ("Pemadam Kebakaran (Damkar)", "113", "Pemadam kebakaran dan penyelamatan.",
     ["kebakaran"], "nasional", 2),
    ("Layanan Darurat 112", "112", "Nomor darurat nasional (tersedia di banyak kota/kabupaten).",
     [], "nasional", 3),
    ("Ambulans Gawat Darurat", "119", "Layanan ambulans & gawat darurat medis (SPGDT).",
     [], "nasional", 4),
    ("Basarnas", "115", "Badan SAR Nasional: pencarian dan pertolongan.",
     ["kebakaran", "banjir", "longsor", "bangunan_roboh", "kecelakaan", "akses_terputus"], "nasional", 5),
    ("Polisi", "110", "Pengamanan lokasi dan pengaturan lalu lintas.",
     [], "nasional", 6),
]


def seed_agencies(db: Session) -> None:
    existing = db.scalars(select(Agency)).all()
    if not existing:
        for name, phone, desc, types, region, rank in SEED_AGENCIES:
            db.add(Agency(name=name, phone=phone, description=desc, incident_types=types, region=region,
                          urgency_rank=rank))
        db.commit()
        return
    # Keep the seeded agencies' incident types in step with the incident type
    # list on databases seeded before it changed.
    seeded_types = {(name, region): types for name, _, _, types, region, _ in SEED_AGENCIES}
    changed = False
    for a in existing:
        types = seeded_types.get((a.name, a.region))
        if types is not None and a.incident_types != types:
            a.incident_types = types
            changed = True
    if changed:
        db.commit()


def suggest(db: Session, incident_type: str, lat: float | None, lng: float | None) -> dict:
    region = region_of(lat, lng) if lat is not None and lng is not None else "nasional"
    rows = db.scalars(select(Agency).order_by(Agency.urgency_rank)).all()
    relevant = [a for a in rows
                if (not a.incident_types or incident_type in a.incident_types)
                and a.region in ("nasional", region)]
    # If the region has its own 112 entry, hide the generic national duplicate.
    if any(a.region == region != "nasional" and a.phone == "112" for a in relevant):
        relevant = [a for a in relevant if not (a.region == "nasional" and a.phone == "112")]
    items = [{"id": a.id, "name": a.name, "phone": a.phone, "description": a.description} for a in relevant]
    return {"region": region, "primary": items[0] if items else None, "others": items[1:]}
