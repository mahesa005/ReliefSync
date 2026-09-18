from sqlalchemy import select

from app.db.models import Skill
from app.services.skills import SEED_SKILLS, list_skills, seed_skills


def test_seed_skills_creates_all_twelve(db):
    seed_skills(db)
    names = {s.name for s in db.scalars(select(Skill))}
    assert names == set(SEED_SKILLS)
    assert len(SEED_SKILLS) == 12


def test_seed_skills_is_idempotent(db):
    seed_skills(db)
    seed_skills(db)
    rows = list(db.scalars(select(Skill)))
    assert len(rows) == len(SEED_SKILLS)


def test_list_skills_returns_ordered_by_id(db):
    seed_skills(db)
    skills = list_skills(db)
    assert [s.name for s in skills] == SEED_SKILLS
    assert all(isinstance(s.id, int) for s in skills)
