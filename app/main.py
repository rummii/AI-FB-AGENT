from __future__ import annotations

import argparse
import logging
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import List

from app.config import Settings, load_settings
from app.models import Article
from app.providers.ai.openai_compatible import OpenAICompatibleClient
from app.providers.facebook.graph_client import FacebookGraphClient
from app.providers.news.newsapi_client import NewsAPIClient
from app.providers.news.rss_client import RSSClient
from app.services.news_pipeline import NewsPipeline
from app.services.post_generator import PostGenerator
from app.services.post_history import PostHistory

LOGGER = logging.getLogger("ai-facebook-news-agent")


def _build_ai_client(settings: Settings) -> OpenAICompatibleClient:
    if not settings.ai_api_key:
        raise RuntimeError("AI_API_KEY is required")

    provider = settings.ai_provider
    if provider in ("openai", "grok", "xai", "groq"):
        base_url = settings.openai_base_url
    elif provider == "gemini":
        base_url = settings.gemini_base_url
    else:
        raise RuntimeError("AI_PROVIDER must be 'openai', 'grok', or 'gemini'")

    LOGGER.info(
        "AI client: provider=%s model=%s base_url=%s",
        provider,
        settings.ai_model,
        base_url,
    )
    return OpenAICompatibleClient(
        provider_name=provider,
        api_key=settings.ai_api_key,
        model=settings.ai_model,
        base_url=base_url,
    )


def _fetch_articles(settings: Settings) -> List[Article]:
    articles: List[Article] = []
    if settings.news_provider == "newsapi":
        newsapi_client = NewsAPIClient(
            api_key=settings.news_api_key,
            language=settings.news_language,
        )
        try:
            articles.extend(newsapi_client.fetch_latest(settings.max_candidates))
        except RuntimeError as exc:
            LOGGER.warning("NewsAPI failed, continuing with RSS fallback: %s", exc)

    rss_client = RSSClient(settings.rss_feeds)
    articles.extend(rss_client.fetch_latest(settings.max_candidates))
    return articles


def _now_in_configured_zone(settings: Settings) -> datetime:
    if settings.post_timezone:
        try:
            from zoneinfo import ZoneInfo

            return datetime.now(ZoneInfo(settings.post_timezone))
        except Exception:
            LOGGER.warning(
                "POST_TIMEZONE '%s' is not recognized; falling back to server local time.",
                settings.post_timezone,
            )
    return datetime.now().astimezone()


def _within_post_window(settings: Settings, history: PostHistory) -> bool:
    """Skip the run unless the current time is allowed to post.

    Two independent gates (both optional):
      - POST_TIMES: only post at the configured hours of POST_TIMEZONE.
      - MIN_POST_INTERVAL_HOURS: never post more often than every N hours.
    """
    if settings.post_times:
        local_now = _now_in_configured_zone(settings)
        if local_now.hour not in settings.post_times:
            LOGGER.info(
                "Skipping: current time is %s (hour %d) but POST_TIMES=%s.",
                local_now.strftime("%Y-%m-%d %H:%M %Z"),
                local_now.hour,
                ",".join(str(hour) for hour in sorted(settings.post_times)),
            )
            return False

    if settings.min_post_interval_hours > 0:
        last_posted = history.last_posted_at()
        if last_posted is not None:
            elapsed = datetime.now(timezone.utc) - last_posted.replace(tzinfo=timezone.utc)
            if elapsed < timedelta(hours=settings.min_post_interval_hours):
                LOGGER.info(
                    "Skipping: last post was %s ago (< MIN_POST_INTERVAL_HOURS=%s).",
                    elapsed,
                    settings.min_post_interval_hours,
                )
                return False

    return True


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Post the latest AI news to a Facebook page.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Generate the next post and print it without publishing to Facebook.",
    )
    parser.add_argument(
        "--show-articles",
        action="store_true",
        help="Print fetched article titles before selecting the best candidate.",
    )
    parser.add_argument(
        "--clear-history",
        action="store_true",
        help="Delete all recorded posts from the history DB. Use this after dry runs "
        "polluted it, so the agent can post articles that were only dry-run tested.",
    )
    return parser.parse_args()


def run() -> int:
    args = _parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    project_root = Path(__file__).resolve().parents[1]
    settings = load_settings(project_root)
    if args.dry_run:
        settings.dry_run = True

    history = PostHistory(settings.history_db_path)

    if args.clear_history:
        history.clear()
        LOGGER.info("Cleared posting history (%s).", settings.history_db_path)
        return 0

    # Manual dry runs always run; only scheduled (non-dry-run) runs honor the window.
    if not args.dry_run and not _within_post_window(settings, history):
        return 0

    pipeline = NewsPipeline(history=history, hours_back=settings.hours_back)
    ai_client = _build_ai_client(settings)
    generator = PostGenerator(
        ai_client=ai_client,
        tone=settings.tone,
        max_chars=settings.max_post_chars,
    )

    articles = _fetch_articles(settings)
    if args.show_articles:
        for article in articles:
            print(f"- {article.title} ({article.source})")

    try:
        selected_article = pipeline.select_best(articles)
    except RuntimeError as exc:
        LOGGER.warning("Nothing to post this run: %s", exc)
        return 0

    try:
        generated_post = generator.build(selected_article)
    except RuntimeError as exc:
        LOGGER.error("Post generation failed (check AI_API_KEY / AI_BASE_URL / AI_MODEL): %s", exc)
        return 1

    LOGGER.info("Selected article: %s", selected_article.title)
    LOGGER.info("Selected URL: %s", selected_article.url)
    LOGGER.info("Dry run: %s", settings.dry_run)

    if settings.dry_run:
        print(generated_post.message)
        return 0

    facebook_client = FacebookGraphClient(
        page_id=settings.facebook_page_id,
        access_token=settings.facebook_page_access_token,
    )
    try:
        response = facebook_client.publish_post(
            message=generated_post.message,
            link=generated_post.article.url,
        )
    except RuntimeError as exc:
        LOGGER.error("Publish failed, nothing was posted: %s", exc)
        return 1

    # Only record history for real published posts, never for dry runs.
    history.save(generated_post)
    LOGGER.info("Facebook response: %s", response)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
