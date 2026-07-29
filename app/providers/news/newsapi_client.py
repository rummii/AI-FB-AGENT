from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from urllib import error, parse, request

from app.models import Article


def _parse_iso8601(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


@dataclass(slots=True)
class NewsAPIClient:
    api_key: str
    language: str = "en"

    def fetch_latest(self, max_items: int) -> list[Article]:
        if not self.api_key:
            return []

        query = (
            '("artificial intelligence" OR AI OR LLM OR "machine learning") AND '
            '(model OR models OR API OR SDK OR agent OR agents OR inference OR training OR benchmark OR '
            '"open source" OR open-source OR developer OR coding OR chip OR GPU OR infrastructure) AND '
            '(OpenAI OR Anthropic OR Google OR Meta OR Microsoft OR NVIDIA OR xAI OR DeepSeek OR Alibaba '
            'OR Baidu OR Tencent OR ByteDance OR Qwen OR Hunyuan OR Zhipu OR Moonshot)'
        )

        params = parse.urlencode(
            {
                "q": query,
                "language": self.language,
                "sortBy": "publishedAt",
                "pageSize": max_items,
                "searchIn": "title,description",
                "apiKey": self.api_key,
            }
        )
        url = f"https://newsapi.org/v2/everything?{params}"
        req = request.Request(url, headers={"User-Agent": "ai-facebook-news-agent/1.0"})

        try:
            with request.urlopen(req, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="ignore")
            raise RuntimeError(f"NewsAPI request failed: {exc.code} {details}") from exc
        except error.URLError as exc:
            raise RuntimeError(f"NewsAPI request failed: {exc.reason}") from exc

        if payload.get("status") != "ok":
            raise RuntimeError(f"NewsAPI returned an unexpected payload: {payload}")

        articles: list[Article] = []
        for item in payload.get("articles", []):
            url_value = (item.get("url") or "").strip()
            title = (item.get("title") or "").strip()
            if not title or not url_value:
                continue
            articles.append(
                Article(
                    title=title,
                    url=url_value,
                    source=(item.get("source") or {}).get("name", "NewsAPI"),
                    summary=(item.get("description") or "").strip(),
                    published_at=_parse_iso8601(item.get("publishedAt")),
                    author=(item.get("author") or "").strip(),
                )
            )
        return articles
