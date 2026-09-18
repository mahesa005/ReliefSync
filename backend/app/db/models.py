"""Database schema (SQLAlchemy). Single source of truth for both SQLite (dev)
and Supabase Postgres -- ``scripts/export_schema.py`` renders it to SQL.

All timestamps are naive UTC (see ``utcnow``).
"""
import uuid
from datetime import UTC, datetime

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .session import Base


def utcnow() -> datetime:
    return datetime.now(UTC).replace(tzinfo=None)


def new_id() -> str:
    return str(uuid.uuid4())


class Skill(Base):
    """Canonical skill catalog (Skill Relawan reference doc, IFest 2026 Tim STEICON).
    id + name only -- domain definitions/groupings live in the LLM prompt, not here."""

    __tablename__ = "skills"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(80), unique=True)


# --------------------------------------------------------------------------
# Accounts. One `User` = base role (can always report). The volunteer status is
# an optional layer (`VolunteerProfile`), never a separate account type.
# --------------------------------------------------------------------------
class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    name: Mapped[str] = mapped_column(String(120))
    phone: Mapped[str] = mapped_column(String(20), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    phone_verified: Mapped[bool] = mapped_column(Boolean, default=False)
    otp_code: Mapped[str | None] = mapped_column(String(6))
    otp_expires_at: Mapped[datetime | None] = mapped_column(DateTime)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    # Last known device location ("lokasi terbaru", FR-5.1)
    lat: Mapped[float | None] = mapped_column(Float)
    lng: Mapped[float | None] = mapped_column(Float)
    location_updated_at: Mapped[datetime | None] = mapped_column(DateTime)

    notify_nearby: Mapped[bool] = mapped_column(Boolean, default=True)  # FR-1.7
    nearby_radius_km: Mapped[float] = mapped_column(Float, default=3.0)  # widget radius (5.7)
    fcm_token: Mapped[str | None] = mapped_column(Text)
    is_simulated: Mapped[bool] = mapped_column(Boolean, default=False)

    volunteer: Mapped["VolunteerProfile | None"] = relationship(
        back_populates="user", uselist=False, cascade="all, delete-orphan"
    )


class VolunteerProfile(Base):
    __tablename__ = "volunteer_profiles"

    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), primary_key=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)  # Availability ON/OFF (4.1)
    available_since: Mapped[datetime] = mapped_column(DateTime, default=utcnow)  # tie-break fallback
    completion_count: Mapped[int] = mapped_column(Integer, default=0)  # Completion History (4.4)
    selection_count: Mapped[int] = mapped_column(Integer, default=0)  # Fairness (4.8)
    # Similar Disaster Experience per disaster type, e.g. {"kebakaran": 3} (4.5)
    disaster_experience: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    user: Mapped[User] = relationship(back_populates="volunteer")
    skills: Mapped[list["VolunteerSkill"]] = relationship(
        back_populates="profile", cascade="all, delete-orphan", order_by="VolunteerSkill.id"
    )


class VolunteerSkill(Base):
    __tablename__ = "volunteer_skills"
    __table_args__ = (UniqueConstraint("user_id", "skill_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("volunteer_profiles.user_id"), index=True)
    skill_id: Mapped[int] = mapped_column(ForeignKey("skills.id"), index=True)
    evidence: Mapped[str] = mapped_column(String(20), default="self_declared")  # or "certified"
    verified_experience: Mapped[int] = mapped_column(Integer, default=0)  # per skill (4.2)

    profile: Mapped[VolunteerProfile] = relationship(back_populates="skills")
    skill: Mapped[Skill] = relationship()


# --------------------------------------------------------------------------
# Reports & extraction
# --------------------------------------------------------------------------
class Report(Base):
    __tablename__ = "reports"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    reporter_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    raw_text: Mapped[str] = mapped_column(Text, default="")  # original, never overwritten (FR-2.5)
    input_mode: Mapped[str] = mapped_column(String(10), default="text")  # text | form
    received_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    # Location is its own field from the start -- never LLM output (5.12)
    lat: Mapped[float] = mapped_column(Float)
    lng: Mapped[float] = mapped_column(Float)
    address_text: Mapped[str | None] = mapped_column(Text)
    is_manual_location: Mapped[bool] = mapped_column(Boolean, default=False)
    contact_phone: Mapped[str | None] = mapped_column(String(20))
    photo_urls: Mapped[list] = mapped_column(JSON, default=list)

    # draft (awaiting extraction confirmation) -> active -> resolved
    status: Mapped[str] = mapped_column(String(20), default="draft", index=True)
    incident_type: Mapped[str] = mapped_column(String(30), default="kebakaran")
    extraction_source: Mapped[str | None] = mapped_column(String(20))  # llm | rule | form
    extraction_ms: Mapped[int | None] = mapped_column(Integer)
    extraction_note: Mapped[str | None] = mapped_column(Text)
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime)

    resolution_started_at: Mapped[datetime | None] = mapped_column(DateTime)  # first arrival
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime)
    resolved_by: Mapped[str | None] = mapped_column(String(20))  # quorum | timeout
    official_status: Mapped[str] = mapped_column(String(20), default="unknown")  # FR-10.4
    official_status_updated_at: Mapped[datetime | None] = mapped_column(DateTime)

    extractions: Mapped[list["ReportExtraction"]] = relationship(
        cascade="all, delete-orphan", order_by="ReportExtraction.id"
    )
    needs: Mapped[list["Need"]] = relationship(
        back_populates="report", cascade="all, delete-orphan", order_by="Need.created_at"
    )
    reporter: Mapped[User] = relationship()


class ReportExtraction(Base):
    """One row per extracted field, with its evidence snippet (FR-3.2)."""

    __tablename__ = "report_extractions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    field_name: Mapped[str] = mapped_column(String(40))
    ai_value: Mapped[str] = mapped_column(Text)  # what the extractor produced
    value: Mapped[str] = mapped_column(Text)  # after reporter confirmation/correction
    evidence: Mapped[str | None] = mapped_column(Text)
    confidence: Mapped[float] = mapped_column(Float, default=0.0)
    corrected: Mapped[bool] = mapped_column(Boolean, default=False)


# --------------------------------------------------------------------------
# Needs, offers (matching/batches) and assignments
# --------------------------------------------------------------------------
class Need(Base):
    __tablename__ = "needs"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    skill_id: Mapped[int] = mapped_column(ForeignKey("skills.id"), index=True)  # Required Skill for SkillMatch
    quota: Mapped[int] = mapped_column(Integer)  # Required Need (FR-4.3)
    # belum_ada | sebagian | penuh | selesai (FR-8.1)
    status: Mapped[str] = mapped_column(String(20), default="belum_ada")
    exhausted: Mapped[bool] = mapped_column(Boolean, default=False)  # all candidates alarmed (FR-5.14)
    current_batch: Mapped[int] = mapped_column(Integer, default=0)
    batch_sent_at: Mapped[datetime | None] = mapped_column(DateTime)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)

    report: Mapped[Report] = relationship(back_populates="needs")
    skill: Mapped[Skill] = relationship()


class Offer(Base):
    """One candidate for one need. `batch_number` is set when this candidate's
    alarm batch is activated; before that it only got a standard notification."""

    __tablename__ = "offers"
    __table_args__ = (UniqueConstraint("need_id", "volunteer_id"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    need_id: Mapped[str] = mapped_column(ForeignKey("needs.id"), index=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    volunteer_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    rank: Mapped[int] = mapped_column(Integer)
    score: Mapped[float] = mapped_column(Float)
    distance_km: Mapped[float] = mapped_column(Float)
    batch_number: Mapped[int | None] = mapped_column(Integer)
    notified_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    alarm_sent_at: Mapped[datetime | None] = mapped_column(DateTime)
    # pending | accepted | rejected | closed
    status: Mapped[str] = mapped_column(String(20), default="pending", index=True)
    rejected_before: Mapped[bool] = mapped_column(Boolean, default=False)
    responded_at: Mapped[datetime | None] = mapped_column(DateTime)
    proactive: Mapped[bool] = mapped_column(Boolean, default=False)  # joined from the map


class Assignment(Base):
    __tablename__ = "assignments"
    __table_args__ = (UniqueConstraint("report_id", "volunteer_id"),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    need_id: Mapped[str] = mapped_column(ForeignKey("needs.id"), index=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    volunteer_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    role: Mapped[str] = mapped_column(String(20))  # utama | tambahan (4.11)
    order_number: Mapped[int] = mapped_column(Integer)  # "relawan ke-N" for this need
    travel_status: Mapped[str] = mapped_column(String(20), default="otw")  # otw | sampai
    status: Mapped[str] = mapped_column(String(20), default="aktif")  # aktif | selesai | dilepas
    accepted_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
    arrived_at: Mapped[datetime | None] = mapped_column(DateTime)

    need: Mapped[Need] = relationship()
    volunteer: Mapped[User] = relationship()


# --------------------------------------------------------------------------
# Collective confirmation (4.13 / 5.11), sightings (5.4/5.7), field accuracy (FR-7.3)
# --------------------------------------------------------------------------
class Participant(Base):
    """Someone entitled to vote 'Konfirmasi Selesai' on a report: the reporter and
    every volunteer recorded on it."""

    __tablename__ = "participants"
    __table_args__ = (UniqueConstraint("report_id", "user_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    role: Mapped[str] = mapped_column(String(20))  # pelapor | relawan
    voted_done_at: Mapped[datetime | None] = mapped_column(DateTime)
    last_prompt_at: Mapped[datetime | None] = mapped_column(DateTime)
    last_response_at: Mapped[datetime | None] = mapped_column(DateTime)
    afk: Mapped[bool] = mapped_column(Boolean, default=False)
    excluded: Mapped[bool] = mapped_column(Boolean, default=False)  # released by the reporter


class Sighting(Base):
    """'Saya melihat kejadian ini' -- display only, never feeds trust (5.7)."""

    __tablename__ = "sightings"
    __table_args__ = (UniqueConstraint("report_id", "user_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class AccuracyFeedback(Base):
    """Post-resolution 'did the field match the report?' (FR-7.3) -> trust score."""

    __tablename__ = "accuracy_feedback"
    __table_args__ = (UniqueConstraint("report_id", "user_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    reporter_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"))
    matches: Mapped[bool] = mapped_column(Boolean)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class NearbyNotice(Base):
    """Which users were notified about a report near them (widget section 1, 5.7)."""

    __tablename__ = "nearby_notices"
    __table_args__ = (UniqueConstraint("report_id", "user_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    report_id: Mapped[str] = mapped_column(ForeignKey("reports.id"), index=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class Notification(Base):
    """In-app notification inbox. The app polls it (works without FCM); when FCM
    is configured the same payload is also pushed."""

    __tablename__ = "notifications"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    # alarm | standard | nearby | confirm_prompt | accuracy_prompt | info
    kind: Mapped[str] = mapped_column(String(30))
    title: Mapped[str] = mapped_column(String(200))
    body: Mapped[str] = mapped_column(Text, default="")
    data: Mapped[dict] = mapped_column(JSON, default=dict)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)
    read_at: Mapped[datetime | None] = mapped_column(DateTime)


class Agency(Base):
    __tablename__ = "agencies"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(120))
    phone: Mapped[str] = mapped_column(String(30))
    description: Mapped[str] = mapped_column(Text, default="")
    incident_types: Mapped[list] = mapped_column(JSON, default=list)  # [] = all
    region: Mapped[str] = mapped_column(String(40), default="nasional")  # nasional | jakarta
    urgency_rank: Mapped[int] = mapped_column(Integer, default=10)  # lower = more urgent


class AppConfig(Base):
    __tablename__ = "app_config"

    key: Mapped[str] = mapped_column(String(80), primary_key=True)
    value: Mapped[dict | list | int | float | str | bool] = mapped_column(JSON)
