# Deploy the AI Facebook Agent to Google Cloud

This agent is a **scheduled CLI script** (not a web app). On Google Cloud the
natural fit is a **Cloud Run Job** triggered by **Cloud Scheduler**:

```text
Cloud Scheduler (cron, every 30 min)
        │  OAuth POST :run
        ▼
Cloud Run Job  ──►  runs `python -m app.main` once, exits
   │   ├── image from Artifact Registry
   │   ├── secrets from Secret Manager (AI key, NewsAPI key, FB token)
   │   └── gcsfuse mount  gs://<PROJECT>-fb-agent-state → /mnt/state
   ▼
Facebook Graph API  +  SQLite history at /mnt/state/posts.db
```

Why a **Job** instead of a Cloud Run **Service** or App Engine: the program has no
HTTP server, exits after one post attempt, and is invoked on a schedule. A Job
runs to completion (with retries and timeouts) and costs nothing while idle.

---

## Files added for GCP

| File | Purpose |
|---|---|
| `Dockerfile` | `python:3.12-slim` + `curl` + `tzdata`; entrypoint `python -m app.main`. No pip deps (stdlib only). |
| `.dockerignore` | Keeps `.env`, `data/`, `.git`, zips and logs out of the image. |
| `cloudbuild.yaml` | Builds the image and pushes it to Artifact Registry (no local Docker needed). |
| `deploy_gcp.sh` | One-shot idempotent deploy (Cloud Shell / bash). Recommended. |
| `deploy_gcp.ps1` | PowerShell equivalent for Windows. |
| `.env.gcp.example` | Documents which vars become secrets vs. plain env vars. |
| `DEPLOY_GCP.md` | This guide. |

---

## Prerequisites

1. **A GCP project** you can write to. This guide uses `osiris-imhotep-507623`.
2. **`gcloud` authenticated**:
   ```bash
   gcloud auth login
   gcloud config set project osiris-imhotep-507623
   ```
3. **Your local `.env`** with real values for at least:
   `AI_API_KEY`, `NEWS_API_KEY`, `FACEBOOK_PAGE_ACCESS_TOKEN` (plus the
   non-secret settings you already have).
4. **Billing enabled** on the project (Cloud Run Jobs and Scheduler require it).
5. Project owner/editor role (the script creates SAs, secrets and IAM bindings).

---

## Step 1 — One-command deploy (recommended)

Open **Google Cloud Shell** (or any bash with `gcloud`), upload/clone the repo,
then from the project root:

```bash
chmod +x deploy_gcp.sh
PROJECT_ID=osiris-imhotep-507623 ./deploy_gcp.sh
```

On Windows PowerShell:

```powershell
.\deploy_gcp.ps1 -ProjectId osiris-imhotep-507623
```

The script is **idempotent** (safe to re-run after code changes) and performs:

1. Enables `run`, `cloudscheduler`, `secretmanager`, `artifactregistry`,
   `cloudbuild`, `storage`, `iam`.
2. Creates the Artifact Registry Docker repo `fb-agent` in `us-central1`.
3. Creates the GCS bucket `gs://<PROJECT>-fb-agent-state` for SQLite history.
4. Creates the runtime service account `fb-agent-runner@<PROJECT>.iam.gserviceaccount.com`
   and grants it bucket + secret access.
5. Reads secrets from your local `.env` and stores them in **Secret Manager**
   (`AI_API_KEY`, `NEWS_API_KEY`, `FACEBOOK_PAGE_ACCESS_TOKEN`).
6. Builds & pushes the image via Cloud Build.
7. Creates/updates the Cloud Run Job `fb-agent-job` with a **gcsfuse** mount.
8. Creates/updates the Cloud Scheduler job `fb-agent-trigger` (`*/30 * * * *` UTC).

> **No local Docker required** — `gcloud builds submit` builds the image in the
> cloud.

---

## Step 2 — Test with a dry run

Execute the job once and wait for it to finish:

```bash
gcloud run jobs execute fb-agent-job \
  --region us-central1 --project osiris-imhotep-507623 --wait
```

The job ships with `DRY_RUN=true` by default, so nothing is posted to Facebook
yet. Read the output:

```bash
gcloud logging read \
  "resource.type=cloud_run_job AND resource.labels.job_name=fb-agent-job" \
  --limit 50 --project osiris-imhotep-507623 --format "value(textPayload)"
```

You should see the selected article, the generated post text, and
`Dry run: True`.

You can also pass a one-off flag by overriding the container arguments:

```bash
gcloud run jobs execute fb-agent-job --region us-central1 \
  --project osiris-imhotep-507623 --args "--dry-run,--show-articles" --wait
```

---

## Step 3 — Go live

Set `DRY_RUN=false` on the job:

```bash
gcloud run jobs update fb-agent-job \
  --region us-central1 --project osiris-imhotep-507623 \
  --update-env-vars DRY_RUN=false
```

From now on Cloud Scheduler runs the job every 30 minutes (UTC). Whether it
actually posts is controlled **inside the app** by:

```env
POST_TIMES=9,21                 # allowed hours (0-23) in POST_TIMEZONE
POST_TIMEZONE=America/New_York  # IANA zone; empty = UTC on Cloud Run
MIN_POST_INTERVAL_HOURS=6       # never post more than once per 6h
```

Outside the window the agent logs `Skipping: current time is ...` and exits 0.

To change these:

```bash
gcloud run jobs update fb-agent-job \
  --region us-central1 --project osiris-imhotep-507623 \
  --update-env-vars POST_TIMES=9,21,POST_TIMEZONE=America/New_York,MIN_POST_INTERVAL_HOURS=6
```


---

## Step 4 — Persistent history (`posts.db`) on GCS

Cloud Run Job containers are **ephemeral**, so the SQLite history lives on a
**GCS bucket mounted with gcsfuse** at `/mnt/state`. `HISTORY_DB_PATH` is set to
`/mnt/state/posts.db`, and the agent recreates the schema automatically on first
run.

Inspect or download the DB:

```bash
# list
gcloud storage ls gs://osiris-imhotep-507623-fb-agent-state/

# download a copy
gcloud storage cp gs://osiris-imhotep-507623-fb-agent-state/posts.db ./posts.db
```

**Reset the history** (e.g. after dry runs, or to allow reposting older
articles):

```bash
gcloud storage rm gs://osiris-imhotep-507623-fb-agent-state/posts.db
```

> gcsfuse is fine for this single-writer, low-frequency workload. If you ever run
> more than one execution concurrently, `MIN_POST_INTERVAL_HOURS` and the
> scheduler interval should keep them from overlapping.

---

## Updating the deployed code

After editing the app, re-run the deploy script — it rebuilds the image and
updates the job in place:

```bash
./deploy_gcp.sh
```

Or just rebuild + update the job:

```bash
gcloud builds submit --config cloudbuild.yaml --project osiris-imhotep-507623 .
gcloud run jobs update fb-agent-job --region us-central1 \
  --project osiris-imhotep-507623 \
  --image us-central1-docker.pkg.dev/osiris-imhotep-507623/fb-agent/fb-agent:latest
```

**Rotating a secret** (e.g. a new Facebook token): add a new version and the
job picks up `:latest` on the next run.

```bash
printf '%s' 'NEW_TOKEN_VALUE' | gcloud secrets versions add FACEBOOK_PAGE_ACCESS_TOKEN \
  --data-file=- --project osiris-imhotep-507623
```

---

## Manual building / creating the resources (no script)

If you prefer to run the steps by hand:

```bash
PROJECT_ID=osiris-imhotep-507623
REGION=us-central1

# APIs
gcloud services enable run.googleapis.com cloudscheduler.googleapis.com \
  secretmanager.googleapis.com artifactregistry.googleapis.com \
  cloudbuild.googleapis.com storage.googleapis.com iam.googleapis.com \
  --project $PROJECT_ID

# Artifact Registry
gcloud artifacts repositories create fb-agent --repository-format=docker \
  --location=$REGION --project $PROJECT_ID

# State bucket
gcloud storage buckets create gs://$PROJECT_ID-fb-agent-state \
  --location=$REGION --uniform-bucket-level-access --project $PROJECT_ID

# Secrets
printf '%s' "$AI_API_KEY"   | gcloud secrets create AI_API_KEY --data-file=- \
  --replication-policy=automatic --project $PROJECT_ID
printf '%s' "$NEWS_API_KEY" | gcloud secrets create NEWS_API_KEY --data-file=- \
  --replication-policy=automatic --project $PROJECT_ID
printf '%s' "$FB_TOKEN"     | gcloud secrets create FACEBOOK_PAGE_ACCESS_TOKEN --data-file=- \
  --replication-policy=automatic --project $PROJECT_ID

# Build + push
gcloud builds submit --config cloudbuild.yaml --project $PROJECT_ID .

# Job (gcsfuse mount + secrets + env)
gcloud run jobs create fb-agent-job \
  --image $REGION-docker.pkg.dev/$PROJECT_ID/fb-agent/fb-agent:latest \
  --region $REGION --project $PROJECT_ID \
  --set-secrets AI_API_KEY=AI_API_KEY:latest,NEWS_API_KEY=NEWS_API_KEY:latest,FACEBOOK_PAGE_ACCESS_TOKEN=FACEBOOK_PAGE_ACCESS_TOKEN:latest \
  --set-env-vars AI_PROVIDER=openai,AI_MODEL=openai/gpt-oss-120b,AI_BASE_URL=https://api.groq.com/openai/v1,NEWS_PROVIDER=newsapi,NEWS_LANGUAGE=en,MAX_CANDIDATES=10,NEWS_LOOKBACK_HOURS=48,MAX_POST_CHARS=420,DRY_RUN=true,HISTORY_DB_PATH=/mnt/state/posts.db,FACEBOOK_PAGE_ID=<PAGE_ID> \
  --add-volume name=state,type=cloud-storage,bucket=$PROJECT_ID-fb-agent-state,mount-path=/mnt/state 
  --tasks 1 --max-retries 1 --task-timeout 600s

# Scheduler
gcloud scheduler jobs create http fb-agent-trigger \
  --location $REGION --project $PROJECT_ID \
  --schedule "*/30 * * * *" --time-zone UTC \
  --uri "https://$REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT_ID/jobs/fb-agent-job:run" \
  --http-method POST \
  --oauth-service-account-email $(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')-compute@developer.gserviceaccount.com
```


---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `PERMISSION_DENIED` creating resources | Enable billing; use an Owner/Editor account; re-run `gcloud auth login`. |
| Job fails with `AI request failed: 403 ... error code: 1010` | Cloudflare blocked urllib. The image includes `curl` and the app falls back to it automatically — confirm you deployed the latest image. |
| `AI request failed: 401` | `AI_API_KEY` secret is wrong, or `AI_BASE_URL`/`AI_MODEL` don't match the provider. Update the secret version and the env vars. |
| `Facebook credentials are missing` | `FACEBOOK_PAGE_ACCESS_TOKEN` secret missing/empty, or `FACEBOOK_PAGE_ID` env var not set. |
| Job logs `Nothing to post this run` | No unseen articles. Reset history (`gcloud storage rm .../posts.db`) or check the feeds. |
| Job logs `Skipping: current time is ...` | `POST_TIMES` is set and the current hour isn't in it — schedule working as intended. |
| Post never appears on Facebook | `DRY_RUN` still `true`. Set it to `false`. |
| `TypeError: ... dataclass ... slots` | Only possible if you changed the base image to Python <3.10. Keep `python:3.12-slim`. |
| Scheduler runs but job never executes | Grant the scheduler SA `roles/run.developer` on the job and `roles/iam.serviceAccountUser` on itself (the deploy script does this). |
| Timezone wrong | The container runs `TZ=UTC`. Set `POST_TIMEZONE` (IANA, e.g. `America/New_York`) so the app evaluates hours correctly. |
| gcsfuse mount errors / read-only | Ensure the runtime SA has `roles/storage.objectAdmin` on the bucket (the script grants this). |

---

## Cost

- **Cloud Run Jobs**: billed per execution-second; this job runs a few seconds
  every 30 min → typically **< $1/month**, often within the free tier.
- **Cloud Scheduler**: 3 jobs free per month.
- **Secret Manager**: 6 active secret versions free; 10k access ops free.
- **Artifact Registry / GCS**: a few cents for a small image + a tiny SQLite file.

