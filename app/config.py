from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _parse_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _load_dotenv(path: Path) -> None:
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


@dataclass(slots=True)
class Settings:
    project_root: Path
    data_dir: Path
    history_db_path: Path
    ai_provider: str
    ai_api_key: str
    ai_model: str
    openai_base_url: str
    gemini_base_url: str
    news_provider: str
    news_api_key: str
    rss_feeds: list[str]
    facebook_page_id: str
    facebook_page_access_token: str
    dry_run: bool
    max_candidates: int
    max_post_chars: int
    tone: str
    hours_back: int
    news_language: str


def load_settings(project_root: Path) -> Settings:
    _load_dotenv(project_root / ".env")

    data_dir = project_root / "data"
    data_dir.mkdir(parents=True, exist_ok=True)

    ai_provider = os.getenv("AI_PROVIDER", "gemini").strip().lower()
    default_models = {
        "openai": "gpt-4o-mini",
        "gemini": "gemini-flash-latest",
    }
    default_model = default_models.get(ai_provider, "gpt-4o-mini")

    raw_feeds = os.getenv(
        "RSS_FEEDS",
        ",".join(
            [
                "https://venturebeat.com/ai/feed/",
                "https://openai.com/news/rss.xml",
                "https://www.anthropic.com/news/rss.xml",
                "https://techcrunch.com/category/artificial-intelligence/feed/",
            ]
        ),
    )

    return Settings(
        project_root=project_root,
        data_dir=data_dir,
        history_db_path=Path(os.getenv("HISTORY_DB_PATH", data_dir / "posts.db")),
        ai_provider=ai_provider,
        ai_api_key=os.getenv("AI_API_KEY", "").strip(),
        ai_model=os.getenv("AI_MODEL", default_model).strip(),
        openai_base_url=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/"),
        gemini_base_url=os.getenv(
            "GEMINI_BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai"
        ).rstrip("/"),
        news_provider=os.getenv("NEWS_PROVIDER", "newsapi").strip().lower(),
        news_api_key=os.getenv("NEWS_API_KEY", "").strip(),
        rss_feeds=[feed.strip() for feed in raw_feeds.split(",") if feed.strip()],
        facebook_page_id=os.getenv("FACEBOOK_PAGE_ID", "").strip(),
        facebook_page_access_token=os.getenv("FACEBOOK_PAGE_ACCESS_TOKEN", "").strip(),
        dry_run=_parse_bool(os.getenv("DRY_RUN"), default=True),
        max_candidates=int(os.getenv("MAX_CANDIDATES", "10")),
        max_post_chars=int(os.getenv("MAX_POST_CHARS", "420")),
        tone=os.getenv("POST_TONE", "concise, useful, and founder-friendly").strip(),
        hours_back=int(os.getenv("NEWS_LOOKBACK_HOURS", "48")),
        news_language=os.getenv("NEWS_LANGUAGE", "en").strip(),
    )