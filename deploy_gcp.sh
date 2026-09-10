#!/usr/bin/env bash
# ==================================================================
# deploy_gcp.sh — idempotent deploy of the AI Facebook News Agent to
# Google Cloud as a Cloud Run Job + Cloud Scheduler trigger.
#
# Run this from the project root, ideally in Google Cloud Shell (curl, gcloud
# and git are preinstalled) or any bash with the Google Cloud SDK:
#
#   PROJECT_ID=osiris-imhotep-507623 ./deploy_gcp.sh
#
# What it does (all steps are safe to re-run):
#   1.  Selects the project and enables the required APIs.
#   2.  Creates the Artifact Registry Docker repo.
#   3.  Creates the GCS bucket that stores the SQLite history (state).
#   4.  Creates a runtime service account and IAM bindings.
#   5.  Creates Secret Manager secrets from your local .env.
#   6.  Builds + pushes the image via Cloud Build.
#   7.  Creates/updates the Cloud Run Job with a gcsfuse volume mount.
#   8.  Creates/updates the Cloud Scheduler job that runs the job on a cron.
#
# Prerequisites:
#   - gcloud authenticated (gcloud auth login) with a project you can write to.
#   - A local .env in the project root containing AI_API_KEY, NEWS_API_KEY and
#     FACEBOOK_PAGE_ACCESS_TOKEN (the script extracts them; nothing else is
#     required from .env).
# ==================================================================
set -euo pipefail

# ------------------------------------------------------------------
# Config — override any of these with environment variables.
# ------------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:-osiris-imhotep-507623}"
REGION="${REGION:-us-central1}"
REPO="${REPO:-fb-agent}"
IMAGE="${IMAGE:-fb-agent}"
TAG="${TAG:-latest}"
JOB_NAME="${JOB_NAME:-fb-agent-job}"
BUCKET="${BUCKET:-${PROJECT_ID}-fb-agent-state}"
STATE_MOUNT_PATH="${STATE_MOUNT_PATH:-/mnt/state}"
SCHEDULER_NAME="${SCHEDULER_NAME:-fb-agent-trigger}"
# Cloud Scheduler cron (Asia/Manila timezone). Fires at 11:00 AM and 6:00 PM
# Philippine Time daily. The app's POST_TIMES / POST_TIMEZONE /
# MIN_POST_INTERVAL_HOURS gates decide whether it actually posts.
SCHEDULE="${SCHEDULE:-0 11,18 * * *}"
SCHEDULER_TIMEZONE="${SCHEDULER_TIMEZONE:-Asia/Manila}"
# Runtime service account used by the Cloud Run Job and Scheduler.
SA_NAME="${SA_NAME:-fb-agent-runner}"
SA_EMAIL="${SA_EMAIL:-${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com}"

IMAGE_URI="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${IMAGE}:${TAG}"
JOB_TASK_TIMEOUT="${JOB_TASK_TIMEOUT:-600s}"
JOB_MAX_RETRIES="${JOB_MAX_RETRIES:-1}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }

# Always operate from the directory this script lives in (the project root),
# so relative paths like Dockerfile / cloudbuild.yaml / .env resolve correctly.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ------------------------------------------------------------------
# 0. Validate prerequisites / extract secrets from local .env
# ------------------------------------------------------------------
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found at $ENV_FILE." >&2
  echo "       Copy .env.example to .env and fill in your real keys first." >&2
  exit 1
fi

# Read a KEY=value from .env without sourcing it (tolerates spaces/quotes).
read_env() {
  local key="$1"
  local line
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" | tail -n 1 || true)"
  [[ -z "$line" ]] && { echo ""; return; }
  line="${line#*=}"
  # strip surrounding whitespace and quotes
  line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
  echo "$line"
}

AI_API_KEY_VALUE="$(read_env AI_API_KEY)"
NEWS_API_KEY_VALUE="$(read_env NEWS_API_KEY)"
FB_TOKEN_VALUE="$(read_env FACEBOOK_PAGE_ACCESS_TOKEN)"

for pair in "AI_API_KEY:$AI_API_KEY_VALUE" "NEWS_API_KEY:$NEWS_API_KEY_VALUE" "FACEBOOK_PAGE_ACCESS_TOKEN:$FB_TOKEN_VALUE"; do
  name="${pair%%:*}"; value="${pair#*:}"
  if [[ -z "$value" ]]; then
    echo "ERROR: $name is missing or empty in $ENV_FILE." >&2
    exit 1
  fi
done

# Non-secret env values (with sensible fallbacks matching .env.example).
AI_PROVIDER_VAL="${AI_PROVIDER:-$(read_env AI_PROVIDER)}"; AI_PROVIDER_VAL="${AI_PROVIDER_VAL:-openai}"
AI_MODEL_VAL="${AI_MODEL:-$(read_env AI_MODEL)}";             AI_MODEL_VAL="${AI_MODEL_VAL:-openai/gpt-oss-120b}"
AI_BASE_URL_VAL="${AI_BASE_URL:-$(read_env AI_BASE_URL)}"
NEWS_PROVIDER_VAL="${NEWS_PROVIDER:-$(read_env NEWS_PROVIDER)}"; NEWS_PROVIDER_VAL="${NEWS_PROVIDER_VAL:-newsapi}"
NEWS_LANGUAGE_VAL="${NEWS_LANGUAGE:-$(read_env NEWS_LANGUAGE)}"; NEWS_LANGUAGE_VAL="${NEWS_LANGUAGE_VAL:-en}"
MAX_CANDIDATES_VAL="${MAX_CANDIDATES:-$(read_env MAX_CANDIDATES)}"; MAX_CANDIDATES_VAL="${MAX_CANDIDATES_VAL:-10}"
NEWS_LOOKBACK_HOURS_VAL="${NEWS_LOOKBACK_HOURS:-$(read_env NEWS_LOOKBACK_HOURS)}"; NEWS_LOOKBACK_HOURS_VAL="${NEWS_LOOKBACK_HOURS_VAL:-48}"
POST_TONE_VAL="${POST_TONE:-$(read_env POST_TONE)}"; POST_TONE_VAL="${POST_TONE_VAL:-concise useful and founder-friendly}"
MAX_POST_CHARS_VAL="${MAX_POST_CHARS:-$(read_env MAX_POST_CHARS)}"; MAX_POST_CHARS_VAL="${MAX_POST_CHARS_VAL:-420}"
DRY_RUN_VAL="${DRY_RUN:-$(read_env DRY_RUN)}"; DRY_RUN_VAL="${DRY_RUN_VAL:-true}"
POST_TIMES_VAL="${POST_TIMES:-$(read_env POST_TIMES)}"
POST_TIMEZONE_VAL="${POST_TIMEZONE:-$(read_env POST_TIMEZONE)}"
MIN_POST_INTERVAL_HOURS_VAL="${MIN_POST_INTERVAL_HOURS:-$(read_env MIN_POST_INTERVAL_HOURS)}"; MIN_POST_INTERVAL_HOURS_VAL="${MIN_POST_INTERVAL_HOURS_VAL:-0}"
FB_PAGE_ID_VAL="$(read_env FACEBOOK_PAGE_ID)"
RSS_FEEDS_VAL="$(read_env RSS_FEEDS)"

log "Deploying ${PROJECT_ID} (${REGION}) image ${IMAGE_URI}"
gcloud config set project "$PROJECT_ID" >/dev/null

# ------------------------------------------------------------------
# 1. Enable APIs
# ------------------------------------------------------------------
log "Enabling required APIs"
gcloud services enable \
  run.googleapis.com \
  cloudscheduler.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  --project "$PROJECT_ID"

# ------------------------------------------------------------------
# 2. Artifact Registry repo
# ------------------------------------------------------------------
log "Ensuring Artifact Registry repo '${REPO}' exists"
if ! gcloud artifacts repositories describe "$REPO" \
      --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="AI Facebook News Agent images" \
    --project "$PROJECT_ID"
else
  echo "    repo already exists"
fi

# ------------------------------------------------------------------
# 3. GCS bucket for persistent state (SQLite history)
# ------------------------------------------------------------------
log "Ensuring GCS state bucket gs://${BUCKET} exists"
if ! gcloud storage buckets describe "gs://${BUCKET}" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${BUCKET}" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    --project "$PROJECT_ID"
else
  echo "    bucket already exists"
fi

# ------------------------------------------------------------------
# 4. Service account + IAM
# ------------------------------------------------------------------
log "Ensuring runtime service account ${SA_EMAIL}"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="AI Facebook News Agent runner" \
    --project "$PROJECT_ID"
  # Give the SA a moment to propagate before IAM bindings.
  sleep 5
else
  echo "    service account already exists"
fi

log "Granting bucket access to ${SA_EMAIL}"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" \
  --project "$PROJECT_ID" >/dev/null

# ------------------------------------------------------------------
# 5. Secrets in Secret Manager
# ------------------------------------------------------------------
create_or_update_secret() {
  local name="$1" value="$2"
  if gcloud secrets describe "$name" --project "$PROJECT_ID" >/dev/null 2>&1; then
    printf '%s' "$value" | gcloud secrets versions add "$name" \
      --data-file=- --project "$PROJECT_ID" >/dev/null
    echo "    updated secret ${name}"
  else
    printf '%s' "$value" | gcloud secrets create "$name" \
      --data-file=- --replication-policy=automatic --project "$PROJECT_ID" >/dev/null
    echo "    created secret ${name}"
  fi
}

log "Syncing secrets from .env into Secret Manager"
create_or_update_secret "AI_API_KEY" "$AI_API_KEY_VALUE"
create_or_update_secret "NEWS_API_KEY" "$NEWS_API_KEY_VALUE"
create_or_update_secret "FACEBOOK_PAGE_ACCESS_TOKEN" "$FB_TOKEN_VALUE"

# Allow the runtime SA to read the secrets (works whether just created or not).
for secret in AI_API_KEY NEWS_API_KEY FACEBOOK_PAGE_ACCESS_TOKEN; do
  gcloud secrets add-iam-policy-binding "$secret" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/secretmanager.secretAccessor" \
    --project "$PROJECT_ID" >/dev/null 2>&1 || true
done

# ------------------------------------------------------------------
# 6. Build + push the image (Cloud Build; no local Docker needed)
# ------------------------------------------------------------------
log "Building and pushing the image"
gcloud builds submit \
  --config cloudbuild.yaml \
  --substitutions="_REGION=${REGION},_REPO=${REPO},_IMAGE=${IMAGE},_TAG=${TAG}" \
  --project "$PROJECT_ID" \
  .

# ------------------------------------------------------------------
# 7. Cloud Run Job (with gcsfuse state mount + secrets)
# ------------------------------------------------------------------
# Use a temp file for --env-vars because values may contain commas,
# which conflict with the comma delimiter of --set-env-vars.
ENV_VARS_FILE=$(mktemp)
cat <<ENVFILE > "$ENV_VARS_FILE"
AI_PROVIDER=${AI_PROVIDER_VAL}
AI_MODEL=${AI_MODEL_VAL}
AI_BASE_URL=${AI_BASE_URL_VAL}
NEWS_PROVIDER=${NEWS_PROVIDER_VAL}
NEWS_LANGUAGE=${NEWS_LANGUAGE_VAL}
MAX_CANDIDATES=${MAX_CANDIDATES_VAL}
NEWS_LOOKBACK_HOURS=${NEWS_LOOKBACK_HOURS_VAL}
MAX_POST_CHARS=${MAX_POST_CHARS_VAL}
DRY_RUN=${DRY_RUN_VAL}
MIN_POST_INTERVAL_HOURS=${MIN_POST_INTERVAL_HOURS_VAL}
POST_TIMES=${POST_TIMES_VAL}
POST_TIMEZONE=${POST_TIMEZONE_VAL}
POST_TONE=${POST_TONE_VAL}
HISTORY_DB_PATH=${STATE_MOUNT_PATH}/posts.db
FACEBOOK_PAGE_ID=${FB_PAGE_ID_VAL}
RSS_FEEDS=${RSS_FEEDS_VAL}
ENVFILE
RUN_SECRETS="AI_API_KEY=AI_API_KEY:latest,NEWS_API_KEY=NEWS_API_KEY:latest,FACEBOOK_PAGE_ACCESS_TOKEN=FACEBOOK_PAGE_ACCESS_TOKEN:latest"
RUN_VOLUME="name=state,type=cloud-storage,bucket=${BUCKET}"
RUN_VOLUME_MOUNT="volume=state,mount-path=${STATE_MOUNT_PATH}"

log "Ensuring Cloud Run Job '${JOB_NAME}'"
if gcloud run jobs describe "$JOB_NAME" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud run jobs update "$JOB_NAME" \
    --image "$IMAGE_URI" \
    --region "$REGION" \
    --project "$PROJECT_ID" \
    --service-account "$SA_EMAIL" \
    --set-secrets "$RUN_SECRETS" \
    --env-vars-file "$ENV_VARS_FILE" \
    --add-volume "$RUN_VOLUME" \
    --add-volume-mount "$RUN_VOLUME_MOUNT" \
    --tasks 1 \
    --max-retries "$JOB_MAX_RETRIES" \
    --task-timeout "$JOB_TASK_TIMEOUT"
else
  gcloud run jobs create "$JOB_NAME" \
    --image "$IMAGE_URI" \
    --region "$REGION" \
    --project "$PROJECT_ID" \
    --service-account "$SA_EMAIL" \
    --set-secrets "$RUN_SECRETS" \
    --env-vars-file "$ENV_VARS_FILE" \
    --add-volume "$RUN_VOLUME" \
    --add-volume-mount "$RUN_VOLUME_MOUNT" \
    --tasks 1 \
    --max-retries "$JOB_MAX_RETRIES" \
    --task-timeout "$JOB_TASK_TIMEOUT"
fi
rm -f "$ENV_VARS_FILE"

# ------------------------------------------------------------------
# 8. Cloud Scheduler trigger
# ------------------------------------------------------------------
# The Scheduler job calls the Cloud Run Admin API to execute the job. Cloud
# Scheduler needs an OAuth service account; the Compute Engine default SA is
# the simplest choice and already exists in most projects.
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
SCHEDULER_SA="${SCHEDULER_SA:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"
JOB_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/${JOB_NAME}:run"

log "Ensuring Cloud Scheduler job '${SCHEDULER_NAME}' (${SCHEDULE} UTC)"
if gcloud scheduler jobs describe "$SCHEDULER_NAME" --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "$SCHEDULER_NAME" \
    --location "$REGION" \
    --project "$PROJECT_ID" \
    --schedule "$SCHEDULE" \
    --time-zone "$SCHEDULER_TIMEZONE" \
    --uri "$JOB_URI" \
    --http-method POST \
    --oauth-service-account-email "$SCHEDULER_SA"
else
  gcloud scheduler jobs create http "$SCHEDULER_NAME" \
    --location "$REGION" \
    --project "$PROJECT_ID" \
    --schedule "$SCHEDULE" \
    --time-zone "$SCHEDULER_TIMEZONE" \
    --uri "$JOB_URI" \
    --http-method POST \
    --oauth-service-account-email "$SCHEDULER_SA"
fi

# Scheduler must be allowed to invoke the job and act as the scheduler SA.
gcloud run jobs add-iam-policy-binding "$JOB_NAME" \
  --region "$REGION" \
  --project "$PROJECT_ID" \
  --member="serviceAccount:${SCHEDULER_SA}" \
  --role="roles/run.developer" >/dev/null 2>&1 \
  || warn "Could not add run.developer to ${SCHEDULER_SA}; grant it manually if executions fail."
gcloud iam service-accounts add-iam-policy-binding "$SCHEDULER_SA" \
  --member="serviceAccount:${SCHEDULER_SA}" \
  --role="roles/iam.serviceAccountUser" \
  --project "$PROJECT_ID" >/dev/null 2>&1 || true

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
log "Deployment complete"
cat <<EOF

Project:      ${PROJECT_ID}
Region:       ${REGION}
Image:        ${IMAGE_URI}
Bucket:       gs://${BUCKET}   (mounted at ${STATE_MOUNT_PATH})
Job:          ${JOB_NAME}
Scheduler:    ${SCHEDULER_NAME}  (${SCHEDULE} UTC)

Next steps:
  1) Run the job once manually to test (DRY_RUN=${DRY_RUN_VAL}):
       gcloud run jobs execute ${JOB_NAME} --region ${REGION} --project ${PROJECT_ID} --wait

  2) Read the logs:
       gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=${JOB_NAME}" \\
         --limit 50 --project ${PROJECT_ID} --format "value(textPayload)"

  3) When the dry run looks good, post for real:
       gcloud run jobs update ${JOB_NAME} --region ${REGION} --project ${PROJECT_ID} \\
         --update-env-vars DRY_RUN=false

  4) Reset posting history (if needed):
       gcloud storage rm gs://${BUCKET}/posts.db
EOF
