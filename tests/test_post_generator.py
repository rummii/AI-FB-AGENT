"""Regression tests for post length handling.

The generator used to hard-slice the AI reply with ``message[:n]``, which cut
words in half (e.g. a post ending in "...it could im"). These tests pin the
word/sentence-boundary behaviour and the URL reservation.
"""

from __future__ import annotations

import unittest
from datetime import datetime, timezone

from app.models import Article
from app.services.post_generator import PostGenerator, _trim_to_words

URL = "https://example.com/news/a-fairly-long-article-slug-for-testing"
MAX_CHARS = 420


class _StubAIClient:
    """Stand-in AI client that records the budget it was handed."""

    provider_name = "stub"
    model = "stub-model"

    def __init__(self, reply: str) -> None:
        self.reply = reply
        self.received_max_chars: int | None = None

    def generate_post(self, article: Article, tone: str, max_chars: int) -> str:
        self.received_max_chars = max_chars
        return self.reply


def _article(url: str = URL) -> Article:
    return Article(
        title="Test article title",
        url=url,
        source="Example News",
        summary="A short summary of the article.",
        published_at=datetime(2026, 9, 10, tzinfo=timezone.utc),
    )


def _generator(reply: str, max_chars: int = MAX_CHARS) -> PostGenerator:
    return PostGenerator(
        ai_client=_StubAIClient(reply), tone="concise", max_chars=max_chars
    )


def _words(text: str) -> set[str]:
    return {word.strip(".,!?\u2026") for word in text.split()}


class TrimToWordsTests(unittest.TestCase):
    def test_short_text_is_returned_unchanged(self) -> None:
        self.assertEqual(_trim_to_words("Short and sweet.", 100), "Short and sweet.")

    def test_empty_text_and_zero_limit(self) -> None:
        self.assertEqual(_trim_to_words("Some text.", 0), "")
        self.assertEqual(_trim_to_words("   ", 50), "")

    def test_result_never_exceeds_limit(self) -> None:
        text = "word " * 200
        for limit in (1, 5, 10, 37, 120, 419):
            with self.subTest(limit=limit):
                self.assertLessEqual(len(_trim_to_words(text, limit)), limit)

    def test_prefers_a_sentence_boundary(self) -> None:
        text = "First sentence here. Second sentence that is much much longer than the rest."
        self.assertEqual(_trim_to_words(text, 30), "First sentence here.")

    def test_never_splits_a_word(self) -> None:
        text = "alpha bravo charlie delta echo foxtrot golf hotel india juliett"
        trimmed = _trim_to_words(text, 25)
        self.assertLessEqual(len(trimmed), 25)
        self.assertEqual(trimmed, "alpha bravo charlie\u2026")


class PostGeneratorTests(unittest.TestCase):
    def test_ai_client_receives_the_body_budget(self) -> None:
        """The model must be asked for a body that leaves room for the URL."""
        client = _StubAIClient("A short post.")
        generator = PostGenerator(ai_client=client, tone="concise", max_chars=MAX_CHARS)
        generator.build(_article())
        self.assertEqual(client.received_max_chars, MAX_CHARS - (len(URL) + 2))

    def test_short_reply_keeps_url_appended(self) -> None:
        post = _generator("Short post.").build(_article())
        self.assertEqual(post.message, f"Short post.\n\n{URL}")

    def test_oversized_reply_is_trimmed_without_splitting_words(self) -> None:
        reply = (
            "Samsung teams up with OpenAI to build custom AI chips. "
            "The partnership adds semiconductor expertise to OpenAI models, promising "
            "faster and more efficient inference for enterprise workloads and tighter "
            "hardware software integration across the whole stack. "
            "If you are building AI products, keep an eye on this hardware roadmap "
            "because the silicon roadmap will shape what you can ship next year."
        )
        post = _generator(reply).build(_article())

        self.assertLessEqual(len(post.message), MAX_CHARS)
        self.assertIn(URL, post.message)

        body = post.message.replace(URL, "").strip()
        # Every word in the body must be a whole word that existed in the reply.
        self.assertTrue(
            _words(body) <= _words(reply),
            f"body introduced a partial word: {_words(body) - _words(reply)}",
        )
        # And it must not simply stop mid-sentence without any cut marker.
        self.assertTrue(
            body.endswith(".") or body.endswith("\u2026"),
            f"body ended abruptly: {body[-20:]!r}",
        )

    def test_url_already_in_reply_is_not_duplicated(self) -> None:
        reply = f"Great AI news today.\n\n{URL}"
        post = _generator(reply).build(_article())
        self.assertEqual(post.message.count(URL), 1)
        self.assertLessEqual(len(post.message), MAX_CHARS)

    def test_tiny_budget_still_preserves_the_url(self) -> None:
        generator = _generator("A very long reply " * 50, max_chars=80)
        post = generator.build(_article())
        self.assertIn(URL, post.message)
        self.assertLessEqual(len(post.message), 80)

    def test_empty_url_is_handled(self) -> None:
        post = _generator("Just a post body.").build(_article(url=""))
        self.assertEqual(post.message, "Just a post body.")

    def test_provider_and_model_are_propagated(self) -> None:
        post = _generator("Hello.").build(_article())
        self.assertEqual(post.provider, "stub")
        self.assertEqual(post.model, "stub-model")
        self.assertEqual(post.article.url, URL)


if __name__ == "__main__":
    unittest.main()
