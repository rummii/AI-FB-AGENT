from __future__ import annotations

from typing import Protocol

from app.models import Article


class AIClient(Protocol):
    provider_name: str
    model: str

    def generate_post(self, article: Article, tone: str, max_chars: int) -> str:
        """Return a Facebook-ready message for the supplied article."""