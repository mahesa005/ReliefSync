"""Skill catalog: seed data and read access (Skill Relawan reference doc, IFest 2026 Tim STEICON)."""
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..db.models import Skill

SEED_SKILLS: list[str] = [
    "P3K",
    "CPR / RJP",
    "Penanganan perdarahan",
    "Penggunaan AED",
    "Pemasangan bidai",
    "Penggunaan tandu",
    "Teknik memindahkan korban",
    "Mengemudi motor",
    "Mengemudi mobil",
    "Dukungan Psikologis Awal / PFA",
    "Penggunaan APAR",
    "Berenang",
]


def seed_skills(db: Session) -> None:
    if db.scalar(select(Skill).limit(1)) is not None:
        return
    for name in SEED_SKILLS:
        db.add(Skill(name=name))
    db.commit()


def list_skills(db: Session) -> list[Skill]:
    return list(db.scalars(select(Skill).order_by(Skill.id)))
