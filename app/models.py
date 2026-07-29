from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime


@dataclass(slots=True)
class Article:
    title: str
    url: str
    source: str
    summary: str = ""
    published_at: datetime | None = None
    author: str = ""


@dataclass(slots=True)
class GeneratedPost:
    article: Article
    message: str
    provider: str
    model: str