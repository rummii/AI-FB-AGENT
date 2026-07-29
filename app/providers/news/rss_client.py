from __future__ import annotations

import html
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime
from email.utils import parsedate_to_datetime
from urllib import error, request

from app.models import Article

AI_KEYWORDS = (
    "ai",
    "artificial intelligence",
    "machine learning",
    "llm",
    "model",
    "openai",
    "anthropic",
    "gemini",
    "agent",
)


def _clean_text(value: str) -> str:
    no_tags = re.sub(r"<[^>]+>", " ", value or "")
    return " ".join(html.unescape(no_tags).split())


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return parsedate_to_datetime(value)
    except (TypeError, ValueError):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None


def _extract_channel_title(root: ET.Element) -> str:
    channel = root.find("./channel/title")
    if channel is not None and channel.text:
        return channel.text.strip()

    feed_title = root.find("{http://www.w3.org/2005/Atom}title")
    if feed_title is not None and feed_title.text:
        return feed_title.text.strip()

    return "RSS Feed"


@dataclass(slots=True)
class RSSClient:
    feeds: list[str]

    def fetch_latest(self, max_items: int) -> list[Article]:
        articles: list[Article] = []
        for feed_url in self.feeds:
            try:
                articles.extend(self._fetch_feed(feed_url, max_items=max_items))
            except RuntimeError:
                continue
        return articles[:max_items]

    def _fetch_feed(self, feed_url: str, max_items: int) -> list[Article]:
        req = request.Request(feed_url, headers={"User-Agent": "ai-facebook-news-agent/1.0"})
        try:
            with request.urlopen(req, timeout=30) as response:
                payload = response.read()
        except error.HTTPError as exc:
            details = exc.read().decode("utf-8", errors="ignore")
            raise RuntimeError(f"RSS request failed: {exc.code} {details}") from exc
        except error.URLError as exc:
            raise RuntimeError(f"RSS request failed: {exc.reason}") from exc

        root = ET.fromstring(payload)
        source_name = _extract_channel_title(root)

        items = root.findall("./channel/item")
        if not items:
            items = root.findall("{http://www.w3.org/2005/Atom}entry")

        parsed: list[Article] = []
        for item in items[:max_items]:
            title = self._get_text(item, "title")
            summary = self._get_text(item, "description") or self._get_text(item, "summary")
            url = self._get_link(item)
            if not title or not url:
                continue

            searchable = f"{title} {summary}".lower()
            if not any(keyword in searchable for keyword in AI_KEYWORDS):
                continue

            published = (
                self._get_text(item, "pubDate")
                or self._get_text(item, "published")
                or self._get_text(item, "updated")
            )
            parsed.append(
                Article(
                    title=_clean_text(title),
                    url=url.strip(),
                    source=source_name,
                    summary=_clean_text(summary),
                    published_at=_parse_date(published),
                )
            )
        return parsed

    @staticmethod
    def _get_text(item: ET.Element, name: str) -> str:
        direct = item.find(name)
        if direct is not None and direct.text:
            return direct.text.strip()

        atom = item.find(f"{{http://www.w3.org/2005/Atom}}{name}")
        if atom is not None and atom.text:
            return atom.text.strip()

        return ""

    @staticmethod
    def _get_link(item: ET.Element) -> str:
        direct = item.find("link")
        if direct is not None:
            if direct.text and direct.text.strip():
                return direct.text.strip()
            href = direct.attrib.get("href")
            if href:
                return href.strip()

        atom = item.find("{http://www.w3.org/2005/Atom}link")
        if atom is not None:
            href = atom.attrib.get("href")
            if href:
                return href.strip()

        return ""