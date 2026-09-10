"""Tests for the Postgres-backed history and its use by the pipeline."""

from __future__ import annotations

import unittest
from datetime import datetime, timezone

from app.models import Article
from app.services.news_pipeline import NewsPipeline
from app.services.post_history import url_hash


class _FakeHistory:
    """Stands in for PostHistory without touching a database."""

    def __init__(self, seen: set[str] | None = None) -> None:
        self._seen = seen or set()
        self.seen_hashes_calls = 0
        self.has_seen_calls = 0

    def seen_hashes(self) -> set[str]:
        self.seen_hashes_calls += 1
        return set(self._seen)

    def has_seen(self, url: str) -> bool:
        self.has_seen_calls += 1
        return url_hash(url) in self._seen


def _article(url: str, title: str = "New model release") -> Article:
    return Article(
        title=title,
        url=url,
        source="Example",
        summary="model api",
        published_at=datetime.now(timezone.utc),
    )


class UrlHashTests(unittest.TestCase):
    def test_stable_and_trims_whitespace(self) -> None:
        self.assertEqual(url_hash("https://a.com/x"), url_hash("  https://a.com/x  "))

    def test_differs_for_different_urls(self) -> None:
        self.assertNotEqual(url_hash("https://a.com/x"), url_hash("https://a.com/y"))


class PipelineHistoryTests(unittest.TestCase):
    def test_history_is_queried_once_per_run(self) -> None:
        history = _FakeHistory()
        pipeline = NewsPipeline(history=history, hours_back=48)
        pipeline.select_best([_article("https://example.com/%d" % i) for i in range(5)])
        self.assertEqual(history.seen_hashes_calls, 1)
        self.assertEqual(history.has_seen_calls, 0)

    def test_seen_articles_are_skipped(self) -> None:
        seen_url = "https://example.com/seen-model-release"
        history = _FakeHistory({url_hash(seen_url)})
        pipeline = NewsPipeline(history=history, hours_back=48)
        chosen = pipeline.select_best(
            [
                _article(seen_url, title="Old model release"),
                _article("https://example.com/fresh-model-release", title="Fresh model release"),
            ]
        )
        self.assertEqual(chosen.url, "https://example.com/fresh-model-release")

    def test_all_seen_raises(self) -> None:
        url = "https://example.com/only-model-release"
        history = _FakeHistory({url_hash(url)})
        pipeline = NewsPipeline(history=history, hours_back=48)
        with self.assertRaises(RuntimeError):
            pipeline.select_best([_article(url)])


if __name__ == "__main__":
    unittest.main()