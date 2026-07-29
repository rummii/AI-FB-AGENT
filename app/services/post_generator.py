from __future__ import annotations

from dataclasses import dataclass

from app.models import Article, GeneratedPost
from app.providers.ai.base import AIClient


@dataclass(slots=True)
class PostGenerator:
    ai_client: AIClient
    tone: str
    max_chars: int

    def build(self, article: Article) -> GeneratedPost:
        url = article.url.strip()
        message = self.ai_client.generate_post(
            article=article,
            tone=self.tone,
            max_chars=self.max_chars,
        ).strip()

        if url not in message:
            reserved = len(url) + 2
            available = max(self.max_chars - reserved, 0)
            trimmed = message[:available].rstrip()
            separator = "\n\n" if trimmed else ""
            message = f"{trimmed}{separator}{url}".strip()
        else:
            message = message[: self.max_chars].strip()

        return GeneratedPost(
            article=article,
            message=message,
            provider=self.ai_client.provider_name,
            model=self.ai_client.model,
        )
