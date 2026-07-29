# AI-FB-AGENT
Facebook news editor
# AI Facebook News Agent

Lightweight Python agent that fetches the latest AI news, generates a Facebook-ready post with OpenRouter or OpenAI, and publishes it to a Facebook page through the Graph API.

## Architecture

```text
app/
  main.py                         # CLI entrypoint
  config.py                       # Env loading and settings
  models.py                       # Shared data models
  providers/
    ai/
      base.py                     # AI client interface
      openai_compatible.py        # OpenRouter/OpenAI-compatible client
    news/
      base.py                     # News provider interface
      newsapi_client.py           # NewsAPI primary source
      rss_client.py               # RSS fallback feeds
    facebook/
      graph_client.py             # Facebook page publisher
  services/
    news_pipeline.py              # Dedupe, filtering, scoring, selection
    post_generator.py             # Generates final post body
    post_history.py               # SQLite history to prevent reposts
data/
  posts.db                        # Created automatically