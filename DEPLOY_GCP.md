# Deploy the AI Facebook Agent to Google Cloud

This agent is a **scheduled CLI** (not a web app). On Google Cloud it runs as a
**Cloud Run Job** triggered by **Cloud Scheduler**:

```text
Cloud Scheduler  (0 11,18 * * * Asia/Manila)
        |  OAuth POST :run
        v
Cloud Run Job  -->  runs `python -m app.main` once, then exits
   |  image:   Artifact Registry
   |  secrets: Secret Manager (AI key, NewsAPI key, FB page token, DATABASE_URL)
   |  state:   Neon Postgres (posting history)
   v
Facebook Graph API
```

The image is **stateless** - no volumes, no bucket. History lives in Neon, so a
manual run and a scheduled run share one record and can never publish the same
article twice.

Why a **Job** rather than a **Service**: there is no HTTP server, the process runs
once and exits, and it is invoked on a schedule. A Job runs to completion (with
retries/timeouts) and costs nothing while idle.

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | `python:3.12-slim` + `curl` + `tzdata`, `pip install` from requirements, entrypoint `python -m app.main`. |
| `.dockerignore` | Keeps `.env`, `data/`, `.git`, zips and logs out of the image. |
| `cloudbuild.yaml` | Builds + pushes the image to Artifact Registry (no local Docker needed). |
| `deploy_gcp.sh` | Idempotent deploy for bash / Cloud Shell. |
| `deploy_gcp.ps1` | Same, for Windows PowerShell (what actually runs locally). |
| `.env.gcp.example` | Which variables become secrets vs. plain env vars. |
| `DEPLOY_GCP.md` | This guide. |

---

## Prerequisites

1. **A GCP project** with billing enabled, e.g. `osiris-imhotep-507623`.
2. **`gcloud` authenticated** as an Owner/Editor:
   ```bash
   gcloud auth login
   gcloud config set project osiris-imhotep-507623
   ```
3. **A Neon database** - copy the connection string from the Neon console
   (**Connect**) into `.env`:
   ```env
   DATABASE_URL=postgresql://user:password@ep-xxx.region.aws.neon.tech/dbname?sslmode=require
   ```
   The `posted_articles` table is created automatically on the first run.
4. **The rest of your `.env`** with real values for `AI_API_KEY`,
   `NEWS_API_KEY`, `FACEBOOK_PAGE_ACCESS_TOKEN` and `FACEBOOK_PAGE_ID`.

---

## Step 1 - Deploy

```bash
# bash / Cloud Shell
./deploy_gcp.sh
```

```powershell
# Windows
.\deploy_gcp.ps1
```

Idempotent - safe to re-run after any code change. It:

1. Enables the required APIs (`run`, `cloudscheduler`, `secretmanager`,
   `artifactregistry`, `cloudbuild`, `iam`).
2. Creates the Artifact Registry repo `fb-agent`.
3. Creates the runtime service account
   `fb-agent-runner@<PROJECT>.iam.gserviceaccount.com`.
4. Reads secrets from `.env` into **Secret Manager** (`AI_API_KEY`,
   `NEWS_API_KEY`, `FACEBOOK_PAGE_ACCESS_TOKEN`, `DATABASE_URL`).
5. Builds and pushes the image via Cloud Build.
6. Creates/updates the Cloud Run Job `fb-agent-job`.
7. Creates/updates the Cloud Scheduler trigger `fb-agent-trigger`
   (`0 11,18 * * *`, `Asia/Manila`).

> No local Docker required - `gcloud builds submit` builds in the cloud.

---

## Step 2 - Dry run

```bash
gcloud run jobs execute fb-agent-job --region us-central1 \
  --project osiris-imhotep-507623 --args="--dry-run,--show-articles" --wait
```

Read the logs:

```bash
gcloud logging read \
  "resource.type=cloud_run_job AND resource.labels.job_name=fb-agent-job" \
  --limit 50 --project osiris-imhotep-507623 --format "value(textPayload)"
```

You should see the fetched articles, the selected one, the generated post and
`Dry run: True`. Nothing is published.

---

## Step 3 - Go live

```bash
gcloud run jobs update fb-agent-job --region us-central1 \
  --project osiris-imhotep-507623 --update-env-vars DRY_RUN=false
```

Cloud Scheduler then fires at **11:00 and 18:00 Asia/Manila**. Two in-app gates
act as a second safety net:

```env
POST_TIMES=11,18
POST_TIMEZONE=Asia/Manila
MIN_POST_INTERVAL_HOURS=6   # 0 = disabled
```

Outside the window the agent logs `Skipping: current time is ...` and exits 0.

---

## Step 4 - Posting history (Neon)

History is one Postgres table, `posted_articles`, created on the first run.
Inspect it in the Neon SQL editor, or with `psql`:

```sql
SELECT created_at, article_title FROM posted_articles ORDER BY created_at DESC LIMIT 10;
```

**Reset** it (e.g. to allow reposting older articles):

```bash
gcloud run jobs execute fb-agent-job --region us-central1 \
  --project osiris-imhotep-507623 --args=--clear-history --wait
```

The pipeline reads every recorded hash in **one query per run** and filters
candidates in memory, so there is no per-article round trip.

---

## Updating the deployed code

```bash
./deploy_gcp.sh          # rebuilds the image and updates the job
```

Or rebuild + update by hand:

```bash
gcloud builds submit --config cloudbuild.yaml --project osiris-imhotep-507623 .
gcloud run jobs update fb-agent-job --region us-central1 \
  --project osiris-imhotep-507623 \
  --image us-central1-docker.pkg.dev/osiris-imhotep-507623/fb-agent/fb-agent:latest
```

**Rotating a secret** - add a new version; the job picks up `:latest` next run:

```bash
printf '%s' 'NEW_VALUE' | gcloud secrets versions add FACEBOOK_PAGE_ACCESS_TOKEN \
  --data-file=- --project osiris-imhotep-507623
```

---

## Manual setup (no script)

```bash
PROJECT_ID=osiris-imhotep-507623
REGION=us-central1

gcloud services enable run.googleapis.com cloudscheduler.googleapis.com \
  secretmanager.googleapis.com artifactregistry.googleapis.com \
  cloudbuild.googleapis.com iam.googleapis.com --project $PROJECT_ID

gcloud artifacts repositories create fb-agent --repository-format=docker \
  --location=$REGION --project $PROJECT_ID

printf '%s' "$AI_API_KEY"    | gcloud secrets create AI_API_KEY --data-file=- \
  --replication-policy=automatic --project $PROJECT_ID
printf '%s' "$NEWS_API_KEY"  | gcloud secrets create NEWS_API_KEY --data-file=- \
  --replication-policy=automatic --project $PROJECT_ID
printf '%s' "$FB_TOKEN"      | gcloud secrets create FACEBOOK_PAGE_ACCESS_TOKEN --data-file=- \
  --replication-policy=automatic --project $PROJECT_ID
printf '%s' "$DATABASE_URL"  | gcloud secrets create DATABASE_URL --data-file=- \
  --replication-policy=automatic --project $PROJECT_ID

gcloud builds submit --config cloudbuild.yaml --project $PROJECT_ID .

gcloud run jobs create fb-agent-job \
  --image $REGION-docker.pkg.dev/$PROJECT_ID/fb-agent/fb-agent:latest \
  --region $REGION --project $PROJECT_ID \
  --set-secrets AI_API_KEY=AI_API_KEY:latest,NEWS_API_KEY=NEWS_API_KEY:latest,FACEBOOK_PAGE_ACCESS_TOKEN=FACEBOOK_PAGE_ACCESS_TOKEN:latest,DATABASE_URL=DATABASE_URL:latest \
  --set-env-vars AI_PROVIDER=openai,AI_MODEL=openai/gpt-oss-120b,AI_BASE_URL=https://api.groq.com/openai/v1,NEWS_PROVIDER=newsapi,NEWS_LANGUAGE=en,MAX_CANDIDATES=10,NEWS_LOOKBACK_HOURS=48,MAX_POST_CHARS=420,DRY_RUN=true,FACEBOOK_PAGE_ID=<PAGE_ID> \
  --tasks 1 --max-retries 1 --task-timeout 600s
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `DATABASE_URL is required` | Add it to `.env` and re-run the deploy (stored as a secret). |
| `psycopg is required` | The image installs it via `requirements.txt`; rebuild if the Dockerfile changed. |
| `Facebook credentials are missing` | `FACEBOOK_PAGE_ACCESS_TOKEN` secret empty, or `FACEBOOK_PAGE_ID` not set. |
| Facebook `OAuthException code 190` | The page token expired. Issue a long-lived **Page** token and update the secret. |
| `AI request failed: 403 ... code 1010` | Cloudflare blocked urllib; the app retries via `curl` (baked into the image). |
| `AI request failed: 401` | Wrong `AI_API_KEY`, or `AI_BASE_URL`/`AI_MODEL` mismatch. |
| `Nothing to post this run` | No unseen articles - reset history or check the feeds. |
| `Skipping: current time is ...` | `POST_TIMES` excludes the current hour - working as intended. |
| Post never appears | `DRY_RUN` is still `true`. |
| Scheduler runs but the job never executes | Grant the scheduler SA `roles/run.developer` on the job and `roles/iam.serviceAccountUser` on itself (the script does this). |
| Wrong posting time | The container runs `TZ=UTC`; set `POST_TIMEZONE` and the scheduler `--time-zone`. |

---

## Cost

- **Cloud Run Jobs** - a few seconds twice a day: well inside the free tier.
- **Cloud Scheduler** - 3 jobs free per month.
- **Secret Manager** - 6 active versions and 10k access ops free.
- **Artifact Registry** - a few cents for a small image.
- **Neon** - the free tier covers this workload (scales to zero when idle).