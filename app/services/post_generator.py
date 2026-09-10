from __future__ import annotations

from dataclasses import dataclass

from app.models import Article, GeneratedPost
from app.providers.ai.base import AIClient


def _trim_to_words(text: str, limit: int) -> str:
    """Trim ``text`` to at most ``limit`` characters without splitting a word.

    Prefers the last complete sentence when it keeps most of the budget;
    otherwise cuts at the last whole word and marks the cut with an ellipsis.
    """
    text = text.strip()
    if limit <= 0:
        return ""
    if len(text) <= limit:
        return text

    window = text[:limit]

    sentence_end = max(
        window.rfind("."),
        window.rfind("!"),
        window.rfind("?"),
        window.rfind("\n"),
    )
    if sentence_end >= int(limit * 0.6):
        return window[: sentence_end + 1].strip()

    ellipsis = "\u2026"
    clipped = window[: max(limit - len(ellipsis), 0)]
    last_space = clipped.rfind(" ")
    if last_space > 0:
        clipped = clipped[:last_space]
    return clipped.rstrip() + ellipsis


@dataclass(slots=True)
class PostGenerator:
    ai_client: AIClient
    tone: str
    max_chars: int

    def build(self, article: Article) -> GeneratedPost:
        url = article.url.strip()
        reserved = len(url) + 2 if url else 0
        body_budget = max(self.max_chars - reserved, 0)

        raw = self.ai_client.generate_post(
            article=article,
            tone=self.tone,
            max_chars=body_budget,
        ).strip()

        # Never let trimming touch the URL: strip it out, trim the body to its
        # own budget, then re-append the intact URL.
        body = raw.replace(url, "").strip() if url and url in raw else raw
        body = _trim_to_words(body, body_budget)

        if url:
            message = f"{body}\n\n{url}".strip() if body else url
        else:
            message = body

        return GeneratedPost(
            article=article,
            message=message,
            provider=self.ai_client.provider_name,
            model=self.ai_client.model,
        )
