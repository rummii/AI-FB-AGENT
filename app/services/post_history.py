from __future__ import annotations

import hashlib
import sqlite3
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from app.models import GeneratedPost


def _url_hash(url: str) -> str:
    return hashlib.sha256(url.strip().encode("utf-8")).hexdigest()


@dataclass(slots=True)
class PostHistory:
    db_path: Path

    def __post_init__(self) -> None:
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS posted_articles (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    article_url TEXT NOT NULL,
                    article_hash TEXT NOT NULL UNIQUE,
                    article_title TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    model TEXT NOT NULL,
                    message TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """
            )
            conn.commit()

    def has_seen(self, url: str) -> bool:
        article_hash = _url_hash(url)
        with sqlite3.connect(self.db_path) as conn:
            row = conn.execute(
                "SELECT 1 FROM posted_articles WHERE article_hash = ? LIMIT 1",
                (article_hash,),
            ).fetchone()
        return row is not None

    def last_posted_at(self) -> datetime | None:
        """Most recent post timestamp (UTC, as stored by SQLite CURRENT_TIMESTAMP)."""
        with sqlite3.connect(self.db_path) as conn:
            row = conn.execute("SELECT MAX(created_at) FROM posted_articles").fetchone()
        value = row[0] if row and row[0] else None
        if not value:
            return None
        try:
            return datetime.fromisoformat(value)
        except ValueError:
            return None

    def clear(self) -> None:
        """Delete all recorded posts, e.g. after dry runs polluted the history DB."""
        with sqlite3.connect(self.db_path) as conn:
            conn.execute("DELETE FROM posted_articles")
            conn.commit()

    def save(self, post: GeneratedPost) -> None:
        with sqlite3.connect(self.db_path) as conn:
            conn.execute(
                """
                INSERT OR IGNORE INTO posted_articles (
                    article_url,
                    article_hash,
                    article_title,
                    provider,
                    model,
                    message
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    post.article.url,
                    _url_hash(post.article.url),
                    post.article.title,
                    post.provider,
                    post.model,
                    post.message,
                ),
            )
            conn.commit()