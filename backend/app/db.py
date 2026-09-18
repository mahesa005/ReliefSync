from collections.abc import Iterator

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import get_settings


class Base(DeclarativeBase):
    pass


def make_engine(url: str):
    if url.startswith("sqlite"):
        engine = create_engine(url, connect_args={"check_same_thread": False})

        @event.listens_for(engine, "connect")
        def _sqlite_pragmas(dbapi_conn, _):
            cur = dbapi_conn.cursor()
            cur.execute("PRAGMA journal_mode=WAL")
            cur.execute("PRAGMA busy_timeout=5000")
            cur.close()

        return engine
    # Supabase connection strings are copied as plain "postgresql://", which
    # SQLAlchemy resolves to the psycopg2 driver by default. We ship psycopg
    # (v3) instead, so force that driver explicitly.
    if url.startswith("postgresql://"):
        url = "postgresql+psycopg://" + url[len("postgresql://"):]
    connect_args = {}
    if url.startswith("postgresql+psycopg://"):
        # Supabase's pooler (port 6543) runs PgBouncer in transaction mode:
        # each statement can land on a different physical connection, so
        # psycopg's server-side prepared statements go stale and Postgres
        # raises "prepared statement ... already exists". Disable them.
        connect_args["prepare_threshold"] = None
        # Supabase's pooler drops physical connections after a period of
        # idleness; the next query on a "still open" client-side connection
        # then blocks for a full reconnect (measured 15-25s cold vs <1s warm --
        # this alone was enough to blow the app's 20s HTTP timeout). Recycling
        # connections before the server would drop them keeps every request
        # on a fresh, fast connection instead of hitting that stall.
        return create_engine(url, pool_pre_ping=True, pool_recycle=180, pool_size=5, max_overflow=5,
                             connect_args=connect_args)
    return create_engine(url, pool_pre_ping=True, connect_args=connect_args)


engine = make_engine(get_settings().database_url)
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
