# ------------------------------------------------------------------
# Dockerfile — AI Facebook News Agent (scheduled CLI).
#
# The agent is a batch job, not a web server: it runs `python -m app.main`
# once and exits. On Google Cloud it runs as a Cloud Run *Job* triggered by
# Cloud Scheduler.
#
# Posting history lives in Neon (serverless Postgres) and is reached over the
# network, so the image is stateless: no mounted volume, nothing to persist
# on the local filesystem.
# ------------------------------------------------------------------
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    TZ=UTC

# curl   -> fallback HTTP client when Cloudflare blocks urllib
#           (see app/providers/ai/openai_compatible.py::_curl_post)
# tzdata -> full IANA timezone database so zoneinfo + POST_TIMEZONE work
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl tzdata ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependencies first so this layer is cached across code changes.
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Application code (see .dockerignore for what is excluded).
COPY app/ ./app/

# Secrets/config (DATABASE_URL, AI_API_KEY, NEWS_API_KEY,
# FACEBOOK_PAGE_ACCESS_TOKEN, ...) are injected at runtime via environment
# variables / Secret Manager, never baked into the image.

CMD ["python", "-m", "app.main"]

