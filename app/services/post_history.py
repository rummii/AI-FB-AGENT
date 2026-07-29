from __future__ import annotations

import hashlib
import sqlite3
from dataclasses import dataclass
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