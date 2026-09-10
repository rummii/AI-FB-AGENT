# ==================================================================
# deploy_gcp.ps1 — idempotent deploy of the AI Facebook News Agent to
# Google Cloud as a Cloud Run Job + Cloud Scheduler trigger.
#
# PowerShell equivalent of deploy_gcp.sh, for running from Windows where
# gcloud is installed. Run from the project root:
#
#   .\deploy_gcp.ps1
#
# Override any setting with parameters, e.g.:
#   .\deploy_gcp.ps1 -ProjectId osiris-imhotep-507623 -Region us-central1 -DryRun false
#
# This requires the Google Cloud SDK (gcloud) to be on PATH and authenticated.
# ==================================================================
[CmdletBinding()]
param(
    [string]$ProjectId = "osiris-imhotep-507623",
    [string]$Region = "us-central1",
    [string]$Repo = "fb-agent",
    [string]$Image = "fb-agent",
    [string]$Tag = "latest",
    [string]$JobName = "fb-agent-job",
    [string]$Bucket = "",
    [string]$StateMountPath = "/mnt/state",
    [string]$SchedulerName = "fb-agent-trigger",
    [string]$Schedule = "0 11,18 * * *",
    [string]$SchedulerTimeZone = "Asia/Manila",
    [string]$SaName = "fb-agent-runner",
    [string]$EnvFile = "",
    [string]$DryRun = "",
    [string]$TaskTimeout = "600s",
    [int]$MaxRetries = 1
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Bucket)) { $Bucket = "$ProjectId-fb-agent-state" }
if ([string]::IsNullOrWhiteSpace($EnvFile)) { $EnvFile = Join-Path $PSScriptRoot ".env" }

$SaEmail = "$SaName@$ProjectId.iam.gserviceaccount.com"
$ImageUri = "$Region-docker.pkg.dev/$ProjectId/$Repo/$Image`:$Tag"

function Write-Step($message) {
    Write-Host ""
    Write-Host "==> $message" -ForegroundColor Cyan
}
function Write-Warn2($message) {
    Write-Host "[WARN] $message" -ForegroundColor Yellow
}

Set-Location -Path $PSScriptRoot

# ------------------------------------------------------------------
# 0. Validate prerequisites / extract secrets from local .env
# ------------------------------------------------------------------
if (-not (Test-Path $EnvFile)) {
    throw ".env not found at $EnvFile. Copy .env.example to .env and fill in your real keys first."
}

function Read-EnvValue([string]$key) {
    $line = Get-Content $EnvFile |
        Where-Object { $_ -match "^\s*$([regex]::Escape($key))\s*=" } |
        Select-Object -Last 1
    if (-not $line) { return "" }
    $value = ($line -split "=", 2)[1]
    $value = $value.Trim()
    $value = $value.Trim('"').Trim("'")
    return $value
}

$AiApiKeyValue = Read-EnvValue "AI_API_KEY"
$NewsApiKeyValue = Read-EnvValue "NEWS_API_KEY"
$FbTokenValue = Read-EnvValue "FACEBOOK_PAGE_ACCESS_TOKEN"

if ([string]::IsNullOrWhiteSpace($AiApiKeyValue)) { throw "AI_API_KEY is missing or empty in $EnvFile." }
if ([string]::IsNullOrWhiteSpace($NewsApiKeyValue)) { throw "NEWS_API_KEY is missing or empty in $EnvFile." }
if ([string]::IsNullOrWhiteSpace($FbTokenValue)) { throw "FACEBOOK_PAGE_ACCESS_TOKEN is missing or empty in $EnvFile." }

function Get-EnvOr([string]$name, [string]$fallback) {
    $envValue = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue }
    $fileValue = Read-EnvValue $name
    if (-not [string]::IsNullOrWhiteSpace($fileValue)) { return $fileValue }
    return $fallback
}

$AiProviderVal  = Get-EnvOr "AI_PROVIDER" "openai"
$AiModelVal     = Get-EnvOr "AI_MODEL" "openai/gpt-oss-120b"
$AiBaseUrlVal   = Get-EnvOr "AI_BASE_URL" ""
$NewsProviderVal = Get-EnvOr "NEWS_PROVIDER" "newsapi"
$NewsLanguageVal = Get-EnvOr "NEWS_LANGUAGE" "en"
$MaxCandidatesVal = Get-EnvOr "MAX_CANDIDATES" "10"
$NewsLookbackVal = Get-EnvOr "NEWS_LOOKBACK_HOURS" "48"
$PostToneVal    = Get-EnvOr "POST_TONE" "concise, useful, and founder-friendly"
$MaxPostCharsVal = Get-EnvOr "MAX_POST_CHARS" "420"
if ([string]::IsNullOrWhiteSpace($DryRun)) { $DryRun = Get-EnvOr "DRY_RUN" "true" }
$PostTimesVal   = Get-EnvOr "POST_TIMES" ""
$PostTimezoneVal = Get-EnvOr "POST_TIMEZONE" ""
$MinPostIntervalVal = Get-EnvOr "MIN_POST_INTERVAL_HOURS" "0"
$FbPageIdVal    = Read-EnvValue "FACEBOOK_PAGE_ID"
$RssFeedsVal    = Read-EnvValue "RSS_FEEDS"

Write-Step "Deploying $ProjectId ($Region) image $ImageUri"
gcloud config set project $ProjectId | Out-Null

# ------------------------------------------------------------------
# 1. Enable APIs
# ------------------------------------------------------------------
Write-Step "Enabling required APIs"
gcloud services enable `
    run.googleapis.com `
    cloudscheduler.googleapis.com `
    secretmanager.googleapis.com `
    artifactregistry.googleapis.com `
    cloudbuild.googleapis.com `
    storage.googleapis.com `
    iam.googleapis.com `
    --project $ProjectId

# ------------------------------------------------------------------
# 2. Artifact Registry repo
# ------------------------------------------------------------------
Write-Step "Ensuring Artifact Registry repo '$Repo' exists"
gcloud artifacts repositories describe $Repo --location $Region --project $ProjectId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    gcloud artifacts repositories create $Repo `
        --repository-format=docker `
        --location=$Region `
        --description="AI Facebook News Agent images" `
        --project $ProjectId
} else {
    Write-Host "    repo already exists"
}

# ------------------------------------------------------------------
# 3. GCS bucket for persistent state (SQLite history)
# ------------------------------------------------------------------
Write-Step "Ensuring GCS state bucket gs://$Bucket exists"
gcloud storage buckets describe "gs://$Bucket" --project $ProjectId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    gcloud storage buckets create "gs://$Bucket" `
        --location=$Region `
        --uniform-bucket-level-access `
        --project $ProjectId
} else {
    Write-Host "    bucket already exists"
}

# ------------------------------------------------------------------
# 4. Service account + IAM
# ------------------------------------------------------------------
Write-Step "Ensuring runtime service account $SaEmail"
gcloud iam service-accounts describe $SaEmail --project $ProjectId 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    gcloud iam service-accounts create $SaName `
        --display-name="AI Facebook News Agent runner" `
        --project $ProjectId
    Start-Sleep -Seconds 5
} else {
    Write-Host "    service account already exists"
}

Write-Step "Granting bucket access to $SaEmail"
gcloud storage buckets add-iam-policy-binding "gs://$Bucket" `
    --member="serviceAccount:$SaEmail" `
    --role="roles/storage.objectAdmin" `
    --project $ProjectId | Out-Null

# ------------------------------------------------------------------
# 5. Secrets in Secret Manager
# ------------------------------------------------------------------
function Set-GcpSecret([string]$name, [string]$value) {
    $tmp = New-TemporaryFile
    try {
        # Write without a trailing newline so the secret matches exactly.
        [System.IO.File]::WriteAllText($tmp.FullName, $value)
        gcloud secrets describe $name --project $ProjectId 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            gcloud secrets create $name --data-file=$($tmp.FullName) --replication-policy=automatic --project $ProjectId | Out-Null
            Write-Host "    created secret $name"
        } else {
            gcloud secrets versions add $name --data-file=$($tmp.FullName) --project $ProjectId | Out-Null
            Write-Host "    updated secret $name"
        }
    } finally {
        Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Syncing secrets from .env into Secret Manager"

# ------------------------------------------------------------------
# 6. Build + push the image (Cloud Build; no local Docker needed)
# ------------------------------------------------------------------
Write-Step "Building and pushing the image"
gcloud builds submit `
    --config cloudbuild.yaml `
    --substitutions="_REGION=$Region,_REPO=$Repo,_IMAGE=$Image,_TAG=$Tag" `
    --project $ProjectId `
    "."

# ------------------------------------------------------------------
# 7. Cloud Run Job (with gcsfuse state mount + secrets)
# ------------------------------------------------------------------
$RunEnvVars = "AI_PROVIDER=$AiProviderVal,AI_MODEL=$AiModelVal,AI_BASE_URL=$AiBaseUrlVal,NEWS_PROVIDER=$NewsProviderVal,NEWS_LANGUAGE=$NewsLanguageVal,MAX_CANDIDATES=$MaxCandidatesVal,NEWS_LOOKBACK_HOURS=$NewsLookbackVal,MAX_POST_CHARS=$MaxPostCharsVal,DRY_RUN=$DryRun,MIN_POST_INTERVAL_HOURS=$MinPostIntervalVal,POST_TIMES=$PostTimesVal,POST_TIMEZONE=$PostTimezoneVal,POST_TONE=$PostToneVal,HISTORY_DB_PATH=$StateMountPath/posts.db,FACEBOOK_PAGE_ID=$FbPageIdVal,RSS_FEEDS=$RssFeedsVal"
$RunSecrets = "AI_API_KEY=AI_API_KEY:latest,NEWS_API_KEY=NEWS_API_KEY:latest,FACEBOOK_PAGE_ACCESS_TOKEN=FACEBOOK_PAGE_ACCESS_TOKEN:latest"
$RunVolume = "name=state,type=cloud-storage,bucket=$Bucket"
$RunVolumeMount = "volume=state,mount-path=$StateMountPath"

Write-Step "Ensuring Cloud Run Job '$JobName'"
gcloud run jobs describe $JobName --region $Region --project $ProjectId 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    gcloud run jobs update $JobName `
        --image $ImageUri `
        --region $Region `
        --project $ProjectId `
        --service-account $SaEmail `
        --set-secrets $RunSecrets `
        --set-env-vars $RunEnvVars `
        --add-volume $RunVolume `
        --add-volume-mount $RunVolumeMount `
        --tasks 1 `
        --max-retries $MaxRetries `
        --task-timeout $TaskTimeout
} else {
    gcloud run jobs create $JobName `
        --image $ImageUri `
        --region $Region `
        --project $ProjectId `
        --service-account $SaEmail `
        --set-secrets $RunSecrets `
        --set-env-vars $RunEnvVars `
        --add-volume $RunVolume `
        --add-volume-mount $RunVolumeMount `
        --tasks 1 `
        --max-retries $MaxRetries `
        --task-timeout $TaskTimeout
}

# ------------------------------------------------------------------
# 8. Cloud Scheduler trigger
# ------------------------------------------------------------------
$ProjectNumber = (gcloud projects describe $ProjectId --format="value(projectNumber)").Trim()
$SchedulerSa = "$ProjectNumber-compute@developer.gserviceaccount.com"
$JobUri = "https://$Region-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$ProjectId/jobs/${JobName}:run"

Write-Step "Ensuring Cloud Scheduler job '$SchedulerName' ($Schedule in $SchedulerTimeZone)"
gcloud scheduler jobs describe $SchedulerName --location $Region --project $ProjectId 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    gcloud scheduler jobs update http $SchedulerName `
        --location $Region `
        --project $ProjectId `
        --schedule $Schedule `
        --time-zone $SchedulerTimeZone `
        --uri $JobUri `
        --http-method POST `
        --oauth-service-account-email $SchedulerSa
} else {
    gcloud scheduler jobs create http $SchedulerName `
        --location $Region `
        --project $ProjectId `
        --schedule $Schedule `
        --time-zone $SchedulerTimeZone `
        --uri $JobUri `
        --http-method POST `
        --oauth-service-account-email $SchedulerSa
}

gcloud run jobs add-iam-policy-binding $JobName `
    --region $Region `
    --project $ProjectId `
    --member="serviceAccount:$SchedulerSa" `
    --role="roles/run.developer" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "Could not add run.developer to $SchedulerSa; grant it manually if executions fail."
}
gcloud iam service-accounts add-iam-policy-binding $SchedulerSa `
    --member="serviceAccount:$SchedulerSa" `
    --role="roles/iam.serviceAccountUser" `
    --project $ProjectId 2>$null | Out-Null

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
Write-Step "Deployment complete"
Write-Host @"

Project:      $ProjectId
Region:       $Region
Image:        $ImageUri
Bucket:       gs://$Bucket   (mounted at $StateMountPath)
Job:          $JobName
Scheduler:    $SchedulerName  ($Schedule UTC)

Next steps:
  1) Run the job once manually to test (DRY_RUN=$DryRun):
       gcloud run jobs execute $JobName --region $Region --project $ProjectId --wait

  2) Read the logs:
       gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=$JobName" --limit 50 --project $ProjectId --format "value(textPayload)"

  3) When the dry run looks good, post for real:
       gcloud run jobs update $JobName --region $Region --project $ProjectId --update-env-vars DRY_RUN=false

  4) Reset posting history (if needed):
       gcloud storage rm gs://$Bucket/posts.db
"@

Set-GcpSecret "AI_API_KEY" $AiApiKeyValue
Set-GcpSecret "NEWS_API_KEY" $NewsApiKeyValue
Set-GcpSecret "FACEBOOK_PAGE_ACCESS_TOKEN" $FbTokenValue

foreach ($secret in @("AI_API_KEY", "NEWS_API_KEY", "FACEBOOK_PAGE_ACCESS_TOKEN")) {
    gcloud secrets add-iam-policy-binding $secret `
        --member="serviceAccount:$SaEmail" `
        --role="roles/secretmanager.secretAccessor" `
        --project $ProjectId 2>$null | Out-Null
}

