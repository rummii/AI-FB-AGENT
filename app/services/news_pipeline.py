from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from urllib.parse import urlsplit, urlunsplit

from app.models import Article
from app.services.post_history import PostHistory

DEV_KEYWORDS = {
    "model": 7,
    "models": 7,
    "llm": 7,
    "api": 7,
    "sdk": 6,
    "agent": 5,
    "agents": 5,
    "open source": 7,
    "open-source": 7,
    "benchmark": 6,
    "inference": 7,
    "training": 6,
    "developer": 6,
    "developers": 6,
    "coding": 6,
    "code": 5,
    "copilot": 4,
    "release": 7,
    "releases": 7,
    "launch": 6,
    "launched": 6,
    "framework": 5,
    "research": 4,
    "multimodal": 5,
    "reasoning": 5,
    "chip": 4,
    "chips": 4,
    "gpu": 4,
    "infrastructure": 5,
    "weights": 7,
    "open-weight": 7,
    "open weights": 7,
    "deploy": 5,
    "deployment": 5,
}

US_AI_KEYWORDS = {
    "openai": 5,
    "anthropic": 5,
    "google": 4,
    "deepmind": 4,
    "meta": 4,
    "microsoft": 4,
    "nvidia": 4,
    "xai": 4,
}

CHINA_AI_KEYWORDS = {
    "deepseek": 7,
    "alibaba": 6,
    "qwen": 7,
    "baidu": 6,
    "ernie": 6,
    "tencent": 6,
    "hunyuan": 6,
    "bytedance": 6,
    "doubao": 6,
    "zhipu": 6,
    "moonshot": 7,
    "kimi": 7,
}

PREFERRED_SOURCES = {
    "openai news": 2,
    "anthropic": 4,
    "venturebeat": 5,
    "techcrunch": 5,
    "the decoder": 5,
    "hugging face": 6,
    "mit technology review": 4,
    "reuters": 4,
    "tom's hardware": 3,
    "artificial intelligence news": 3,
}

BLOCKED_DOMAINS = {
    "biztoc.com",
    "slashdot.org",
    "cryptobriefing.com",
}

LOW_QUALITY_DOMAINS = {
    "slashdot.org": 8,
    "cryptobriefing.com": 10,
    "biztoc.com": 15,
    "pymnts.com": 6,
    "iphoneincanada.ca": 5,
}

NOISE_KEYWORDS = {
    "crypto": 10,
    "celebrity": 8,
    "photo": 6,
    "martech": 8,
    "marketing": 7,
    "students": 6,
    "county": 6,
    "city council": 6,
    "lawsuit": 4,
    "sports": 6,
    "price prediction": 12,
    "investor": 5,
    "investors": 5,
    "funding": 4,
    "seed": 4,
    "series a": 4,
    "alliance": 6,
    "breach": 5,
    "absent": 4,
    "joins": 3,
    "join": 3,
}

TITLE_PREFERRED_PATTERNS = (
    "releases",
    "launches",
    "launched",
    "introducing",
    "open-source",
    "open source",
    "weights",
    "api",
    "sdk",
    "model",
    "developer",
    "benchmark",
    "inference",
    "training",
)


def _normalize_url(url: str) -> str:
    parsed = urlsplit(url.strip())
    return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))


def _hostname(url: str) -> str:
    return urlsplit(url).netloc.lower().removeprefix("www.")


def _keyword_score(text: str, weights: dict[str, int]) -> int:
    return sum(weight for keyword, weight in weights.items() if keyword in text)


def _article_score(article: Article) -> int:
    title = article.title.lower()
    summary = article.summary.lower()
    source = article.source.lower()
    domain = _hostname(article.url)
    combined = f"{title} {summary}"

    score = 0
    score += _keyword_score(title, DEV_KEYWORDS) * 3
    score += _keyword_score(summary, DEV_KEYWORDS)
    score += _keyword_score(combined, US_AI_KEYWORDS)
    score += _keyword_score(combined, CHINA_AI_KEYWORDS)
    score += _keyword_score(source, PREFERRED_SOURCES)
    score -= _keyword_score(combined, NOISE_KEYWORDS)
    score -= LOW_QUALITY_DOMAINS.get(domain, 0)

    if any(pattern in title for pattern in TITLE_PREFERRED_PATTERNS):
        score += 8

    has_dev_signal = any(keyword in combined for keyword in DEV_KEYWORDS)
    has_region_signal = any(keyword in combined for keyword in US_AI_KEYWORDS) or any(
        keyword in combined for keyword in CHINA_AI_KEYWORDS
    )

    if not has_dev_signal:
        score -= 15
    if not has_region_signal:
        score -= 4

    return score


def _as_utc(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


@dataclass(slots=True)
class NewsPipeline:
    history: PostHistory
    hours_back: int

    def select_best(self, articles: list[Article]) -> Article:
        if not articles:
            raise RuntimeError("No articles were fetched from NewsAPI or RSS feeds")

        cutoff = datetime.now(timezone.utc) - timedelta(hours=self.hours_back)
        unique: dict[str, Article] = {}
        for article in articles:
            normalized_url = _normalize_url(article.url)
            if not normalized_url:
                continue
            if self.history.has_seen(normalized_url):
                continue
            if _hostname(normalized_url) in BLOCKED_DOMAINS:
                continue

            article.url = normalized_url
            article.published_at = _as_utc(article.published_at)
            existing = unique.get(normalized_url)
            if existing is None or self._is_better(article, existing):
                unique[normalized_url] = article

        fresh_articles = [
            article
            for article in unique.values()
            if article.published_at is None or article.published_at >= cutoff
        ]
        ranked = fresh_articles or list(unique.values())
        if not ranked:
            raise RuntimeError("No unseen articles are available to post")

        positively_ranked = [article for article in ranked if _article_score(article) > 0]
        ranked = positively_ranked or ranked

        ranked.sort(
            key=lambda article: (
                _article_score(article),
                article.published_at or datetime.min.replace(tzinfo=timezone.utc),
            ),
            reverse=True,
        )
        return ranked[0]

    @staticmethod
    def _is_better(candidate: Article, current: Article) -> bool:
        candidate_has_summary = bool(candidate.summary)
        current_has_summary = bool(current.summary)
        if candidate_has_summary != current_has_summary:
            return candidate_has_summary
        return _article_score(candidate) >= _article_score(current)
