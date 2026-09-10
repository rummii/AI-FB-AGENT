# ------------------------------------------------------------------
# Dockerfile — AI Facebook News Agent (scheduled CLI).
#
# The agent is a batch job, not a web server: it runs `python -m app.main`
# once and exits. On Google Cloud it is meant to run as a Cloud Run *Job*
# triggered by Cloud Scheduler.
#
# This project has ZERO third-party Python dependencies (standard library
# only), so there is no `pip install` step. We only need:
#   - curl  : used as a fallback HTTP client when Cloudflare blocks urllib
#             (see app/providers/ai/openai_compatible.py::_curl_post).
#   - tzdata: full IANA timezone database so zoneinfo + POST_TIMEZONE work
#             (python:3.12-slim does not ship the complete tz database).
# ------------------------------------------------------------------
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    TZ=UTC

# curl  -> Cloudflare/urllib fallback + general debugging
# tzdata -> IANA zones for POST_TIMEZONE (zoneinfo)
# gcsfuse is provided by the Cloud Run volume mount, not the image.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl tzdata ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the application package and support files (see .dockerignore for what
# is excluded: secrets, local DB, logs, build artifacts).
COPY app/ ./app/
COPY requirements.txt ./requirements.txt

# Persistent state lives on a mounted volume in production. Locally it falls
# back to the in-container ./data directory created automatically at runtime.
RUN mkdir -p /app/data

# Secrets (AI_API_KEY, NEWS_API_KEY, FACEBOOK_PAGE_ACCESS_TOKEN, ...) are
# injected at runtime via env vars / Secret Manager, never baked into the image.
# The agent loads .env only if present; on Cloud Run we inject env directly.

# Default HISTORY_DB_PATH points at the mounted state volume when present.
# Cloud Run Job sets this explicitly; /app/data is the local fallback.
ENV HISTORY_DB_PATH=/app/data/posts.db

CMD ["python", "-m", "app.main"]
