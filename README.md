# AI Facebook News Agent

A small, stateless Python agent that fetches the latest AI news, writes a
Facebook-ready post with an OpenAI-compatible model (Groq, OpenAI, Gemini, xAI),
and publishes it to a Facebook Page through the Graph API - on a schedule.

## Architecture

```text
app/
  main.py                  # CLI entrypoint
  config.py                # Env loading and settings
  models.py                # Shared data models
  providers/
    ai/
      base.py              # AI client interface
      openai_compatible.py # OpenAI/Groq/Gemini/xAI client
    news/
      base.py              # News provider interface
      newsapi_client.py    # NewsAPI primary source
      rss_client.py        # RSS fallback feeds
    facebook/
      graph_client.py      # Facebook Page publisher
  services/
    news_pipeline.py       # Dedupe, filtering, scoring, selection
    post_generator.py      # Builds the final post body
    post_history.py        # Postgres (Neon) history - prevents reposts
tests/
  test_post_generator.py   # Length/trimming regression tests
```

History lives in **Neon (Postgres)** via `DATABASE_URL`. The `posted_articles`
table is created automatically on the first run, and the pipeline reads it in a
single query per run.

## Setup

1. `cp .env.example .env` and fill in:
   - `AI_PROVIDER`, `AI_API_KEY`, `AI_MODEL`, `AI_BASE_URL`
   - `NEWS_API_KEY` (optional - RSS feeds are the fallback)
   - `FACEBOOK_PAGE_ID`, `FACEBOOK_PAGE_ACCESS_TOKEN` (a long-lived **Page** token)
   - `DATABASE_URL` (Neon connection string)
2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

## Run

```bash
python --version                               # 3.10+ required
python -m app.main --dry-run --show-articles   # preview; nothing is published
python -m app.main                             # publish one post
python -m app.main --clear-history             # wipe the history table
```

## Tests

```bash
python -m unittest discover -s tests -v
```

## Scheduling

The agent is a batch job: run it as a **Cloud Run Job** triggered by **Cloud
Scheduler** (twice daily, 11:00 and 18:00 Asia/Manila). See
[DEPLOY_GCP.md](DEPLOY_GCP.md).

The in-app gates `POST_TIMES`, `POST_TIMEZONE` and `MIN_POST_INTERVAL_HOURS` act
as a second safety net so it never double-posts.

## Notes

- `DRY_RUN=true` generates and prints a post without publishing it.
- An article is recorded in history only **after** a successful publish.
- The Docker image is stateless: no volumes and no local database.