from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from app.models import GeneratedPost

# Created on first use, so a fresh Neon database needs no manual setup step.
# created_at is TIMESTAMPTZ; the public API hands back naive UTC (see below) to
# match what callers have always expected.
_SCHEMA = """
CREATE TABLE IF NOT EXISTS posted_articles (
    id            BIGSERIAL PRIMARY KEY,
    article_hash  TEXT        NOT NULL UNIQUE,
    article_url   TEXT        NOT NULL,
    article_title TEXT        NOT NULL,
    provider      TEXT        NOT NULL,
    model         TEXT        NOT NULL,
    message       TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
)
"""


def url_hash(url: str) -> str:
    """Stable identity for an article URL, used for de-duplication."""
    return hashlib.sha256(url.strip().encode("utf-8")).hexdigest()


@dataclass(slots=True)
class PostHistory:
    """Posting history stored in Neon (serverless Postgres).

    This replaces a SQLite database that lived on a gcsfuse mount. gcsfuse does
    not implement the POSIX file semantics SQLite needs, so journal writes
    failed and the job hung. Postgres over TCP avoids that entirely, and having
    one shared record means a manual local run and a scheduled cloud run can
    never publish the same article twice.

    ``dsn`` is a Postgres connection string (``postgresql://...``) supplied via
    the ``DATABASE_URL`` environment variable. The connection and schema are
    created lazily, so constructing this object performs no I/O.
    """

    dsn: str
    _conn: Any = field(default=None, init=False, repr=False)

    def _connection(self) -> Any:
        """Return a live connection, opening it (and the schema) on first use."""
        if self._conn is None or self._conn.closed:
            try:
                import psycopg
            except ModuleNotFoundError as exc:  # pragma: no cover - environment issue
                raise RuntimeError(
                    "psycopg is required to use DATABASE_URL. "
                    "Install it with: pip install 'psycopg[binary]'"
                ) from exc

            self._conn = psycopg.connect(self.dsn, autocommit=True)
            self._conn.execute(_SCHEMA)
        return self._conn

    def seen_hashes(self) -> set[str]:
        """Every recorded article hash, in a single query.

        Lets the pipeline test all candidates against an in-memory set rather
        than issuing one round-trip per article.
        """
        rows = (
            self._connection()
            .execute("SELECT article_hash FROM posted_articles")
            .fetchall()
        )
        return {row[0] for row in rows}

    def has_seen(self, url: str) -> bool:
        row = (
            self._connection()
            .execute(
                "SELECT 1 FROM posted_articles WHERE article_hash = %s",
                (url_hash(url),),
            )
            .fetchone()
        )
        return row is not None

    def last_posted_at(self) -> datetime | None:
        """Most recent post time as a naive UTC datetime, or None if never."""
        row = (
            self._connection()
            .execute("SELECT max(created_at) FROM posted_articles")
            .fetchone()
        )
        value = row[0] if row else None
        if value is None:
            return None
        if value.tzinfo is not None:
            value = value.astimezone(timezone.utc).replace(tzinfo=None)
        return value

    def save(self, post: GeneratedPost) -> None:
        self._connection().execute(
            """
            INSERT INTO posted_articles (
                article_hash, article_url, article_title, provider, model, message
            ) VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (article_hash) DO NOTHING
            """,
            (
                url_hash(post.article.url),
                post.article.url,
                post.article.title,
                post.provider,
                post.model,
                post.message,
            ),
        )

    def clear(self) -> None:
        self._connection().execute("DELETE FROM posted_articles")

    def close(self) -> None:
        if self._conn is not None and not self._conn.closed:
            self._conn.close()
        self._conn = None
