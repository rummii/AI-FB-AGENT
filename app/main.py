from __future__ import annotations

import argparse
import logging
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

    if settings.ai_provider == "openrouter":
        base_url = settings.openrouter_base_url
    elif settings.ai_provider == "openai":
        base_url = settings.openai_base_url
    else:
        raise RuntimeError("AI_PROVIDER must be either 'openrouter' or 'openai'")

    return OpenAICompatibleClient(
        provider_name=settings.ai_provider,
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
    return parser.parse_args()


def run() -> int:
    args = _parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    project_root = Path(__file__).resolve().parents[1]
    settings = load_settings(project_root)
    if args.dry_run:
        settings.dry_run = True

    history = PostHistory(settings.history_db_path)
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

    selected_article = pipeline.select_best(articles)
    generated_post = generator.build(selected_article)

    LOGGER.info("Selected article: %s", selected_article.title)
    LOGGER.info("Selected URL: %s", selected_article.url)
    LOGGER.info("Dry run: %s", settings.dry_run)

    if settings.dry_run:
        print(generated_post.message)
        history.save(generated_post)
        return 0

    facebook_client = FacebookGraphClient(
        page_id=settings.facebook_page_id,
        access_token=settings.facebook_page_access_token,
    )
    response = facebook_client.publish_post(
        message=generated_post.message,
        link=generated_post.article.url,
    )
    history.save(generated_post)
    LOGGER.info("Facebook response: %s", response)
    return 0


if __name__ == "__main__":
    raise SystemExit(run())
