from __future__ import annotations

from typing import Protocol

from app.models import Article


class NewsProvider(Protocol):
    def fetch_latest(self, max_items: int) -> list[Article]:
        """Return the latest AI-related articles available from the provider."""