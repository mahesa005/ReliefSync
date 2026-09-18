"""Manual tuning harness for the Groq extraction prompt -- NOT part of the
automated test suite (deliberately not named test_*.py so pytest won't
collect it). Run against real report text, eyeball the output, adjust
DOMAIN_RULES/SYSTEM_PROMPT_TEMPLATE in app/services/extraction.py, repeat.

    cd backend
    .venv/Scripts/python.exe -m scripts.tune_extraction

Requires GROQ_API_KEY set in backend/.env (or the environment) to exercise
the real LLM path -- without it, every case falls back to the rule-based
path and you'll only see title/description/incident_type, no needs.

Edit CASES below freely; each is (label, report_text). The 10 below are
seeded to probe the specific guardrails written into DOMAIN_RULES:
  1. Baseline           -- one clear skill, sanity check
  2. Multi-skill         -- several skills genuinely needed at once
  3. No inheritance       -- only P3K stated; must NOT also pull CPR/AED/bidai
  4. Swimming irrelevant  -- shallow flood; must NOT include Berenang
  5. Swimming relevant    -- high water, person stranded; SHOULD include Berenang
  6. General task         -- only distribution/data-entry; should yield no skill
  7. Vague/low-signal     -- barely any actionable detail
  8. Mixed language       -- Indonesian + English in the same report
  9. Out-of-scope skill   -- asks for rubble search-and-rescue (explicitly excluded)
  10. Large-scale/quota    -- many victims; quota must clamp to MAX_QUOTA (50)
"""
import asyncio

from sqlalchemy import select

from app.db.models import Skill
from app.db.session import Base, SessionLocal, engine
from app.services.extraction import extract
from app.services.skills import seed_skills

CASES: list[tuple[str, str]] = [
    ("1. Baseline (P3K only)",
     "Ada yang pingsan di acara kumpul warga, butuh pertolongan pertama segera."),
    ("2. Multi-skill fire scenario",
     "Kebakaran rumah di Jalan Melati, ada korban luka bakar dan lansia yang harus "
     "dievakuasi dari lantai 2, api masih menyala dan asap tebal."),
    ("3. No-inheritance trap (P3K stated, not CPR/AED/bidai)",
     "Ada korban luka ringan di lokasi kecelakaan motor, butuh orang yang bisa P3K "
     "untuk menangani lukanya."),
    ("4. Swimming irrelevant (shallow flood)",
     "Banjir setinggi mata kaki di kompleks perumahan, warga butuh bantuan logistik "
     "makanan dan air bersih."),
    ("5. Swimming relevant (high water, stranded)",
     "Banjir sudah setinggi dada orang dewasa, ada warga terjebak di atap rumah dan "
     "butuh dievakuasi melewati genangan air yang tinggi."),
    ("6. General task trap (no technical skill)",
     "Butuh relawan untuk membagikan bantuan sembako dan mendata pengungsi di posko "
     "pengungsian."),
    ("7. Vague/low-signal",
     "Ada kejadian di kampung sebelah, tolong dibantu."),
    ("8. Mixed language",
     "There's a fire at my neighbor's house, kebakaran rumah tetangga, ada yang "
     "terjebak di dalam dan butuh dievakuasi."),
    ("9. Out-of-scope skill (rubble search-and-rescue)",
     "Ada bangunan runtuh akibat gempa, butuh tim search and rescue untuk mencari "
     "korban yang tertimbun di reruntuhan."),
    ("10. Large-scale incident (quota clamp)",
     "Gempa besar mengguncang permukiman padat, banyak korban terluka parah, "
     "diperkirakan lebih dari 100 warga butuh pertolongan pertama dan evakuasi masal "
     "segera dilakukan."),
]


async def run() -> None:
    Base.metadata.create_all(engine)
    with SessionLocal() as db:
        seed_skills(db)
        skills = list(db.scalars(select(Skill)))
    skill_names = {s.id: s.name for s in skills}

    for i, (label, text) in enumerate(CASES):
        if i > 0:
            await asyncio.sleep(8)  # stay under Groq free-tier TPM rate limit
        result = await extract(text, skills)
        print(f"\n{'=' * 70}\n{label}\n{'=' * 70}")
        print(f"laporan   : {text}")
        print(f"source    : {result.source}   incident_type: {result.incident_type}   "
              f"elapsed_ms: {result.elapsed_ms}")
        if result.note:
            print(f"note      : {result.note}")
        print(f"title     : {result.title}")
        print(f"description: {result.description}")
        if result.needs:
            print("needs:")
            for n in result.needs:
                name = skill_names.get(n["skill_id"], f"??? unknown skill_id={n['skill_id']}")
                print(f"  - {name} (skill_id={n['skill_id']}) quota={n['quota']}")
        else:
            print("needs     : (kosong)")


if __name__ == "__main__":
    asyncio.run(run())
