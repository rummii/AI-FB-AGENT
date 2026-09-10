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
    [string]$SchedulerName = "fb-agent-trigger",
    [string]$Schedule = "0 11,18 * * *",
    [string]$SchedulerTimeZone = "Asia/Manila",
    [string]$SaName = "fb-agent-runner",
    [string]$EnvFile = "",
    [string]$DryRun = "",
    [string]$TaskTimeout = "600s",
    [int]$MaxRetries = 1
)

$ErrorActionPreference = "Continue"
# NOTE: intentionally NOT "Stop". gcloud is a Python/native launcher that writes
# progress and informational text to stderr (e.g. "[environment: untagged]",
# "Encryption: Google-managed key"). Windows PowerShell 5.1 converts that
# stderr noise into terminating NativeCommandErrors, which would abort the
# deploy even though the gcloud command succeeded. Every gcloud call below goes
# through Invoke-Gcloud / Test-GcloudResource, which capture output and let us
# branch on $LASTEXITCODE instead.
# The one place we DO want to fail hard is reading the local .env, handled by
# explicit throw statements.

# (no GCS bucket: history lives in Neon)
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

# Windows PowerShell 5.1 turns native stderr output into a terminating
# NativeCommandError under ErrorActionPreference=Stop, even when the command
# succeeded. gcloud writes almost everything (progress, "Encryption: ...",
# "[environment: untagged]") to stderr, so every gcloud call must be wrapped.
# This helper runs gcloud, merges stderr into stdout, and returns the exit code.
function Invoke-Gcloud {
    param(
        [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )
    # 2>&1 inside the script block keeps PowerShell from raising NativeCommandError.
    $output = & gcloud @Arguments 2>&1
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        $output | ForEach-Object { Write-Host $_ }
    }
    return $exit
}

# Run a gcloud command and discard stdout/stderr, returning only the exit code.
function Test-GcloudResource {
    param(
        [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )
    $null = & gcloud @Arguments 2>&1
    return $LASTEXITCODE
}

# Run a gcloud command and return its stdout as a string array (stderr merged,
# then filtered out of the result). Use for reads like `projects describe`.
function Get-GcloudOutput {
    param(
        [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )
    $raw = & gcloud @Arguments 2>&1
    return ($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
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
$DatabaseUrlValue = Read-EnvValue "DATABASE_URL"

if ([string]::IsNullOrWhiteSpace($AiApiKeyValue)) { throw "AI_API_KEY is missing or empty in $EnvFile." }
if ([string]::IsNullOrWhiteSpace($NewsApiKeyValue)) { throw "NEWS_API_KEY is missing or empty in $EnvFile." }
if ([string]::IsNullOrWhiteSpace($FbTokenValue)) { throw "FACEBOOK_PAGE_ACCESS_TOKEN is missing or empty in $EnvFile." }
if ([string]::IsNullOrWhiteSpace($DatabaseUrlValue)) { throw "DATABASE_URL is missing or empty in $EnvFile." }

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
$PostToneVal    = Get-EnvOr "POST_TONE" "concise useful and founder-friendly"
$MaxPostCharsVal = Get-EnvOr "MAX_POST_CHARS" "420"
if ([string]::IsNullOrWhiteSpace($DryRun)) { $DryRun = Get-EnvOr "DRY_RUN" "true" }
$PostTimesVal   = Get-EnvOr "POST_TIMES" ""
$PostTimezoneVal = Get-EnvOr "POST_TIMEZONE" ""
$MinPostIntervalVal = Get-EnvOr "MIN_POST_INTERVAL_HOURS" "0"
$FbPageIdVal    = Read-EnvValue "FACEBOOK_PAGE_ID"
$RssFeedsVal    = Read-EnvValue "RSS_FEEDS"

Write-Step "Deploying $ProjectId ($Region) image $ImageUri"
Invoke-Gcloud config set project $ProjectId | Out-Null

# ------------------------------------------------------------------
# 1. Enable APIs
# ------------------------------------------------------------------
Write-Step "Enabling required APIs"
Invoke-Gcloud services enable `
    run.googleapis.com `
    cloudscheduler.googleapis.com `
    secretmanager.googleapis.com `
    artifactregistry.googleapis.com `
    cloudbuild.googleapis.com `
    storage.googleapis.com `
    iam.googleapis.com `
    --project $ProjectId | Out-Null

# ------------------------------------------------------------------
# 2. Artifact Registry repo
# ------------------------------------------------------------------
Write-Step "Ensuring Artifact Registry repo '$Repo' exists"
if ((Test-GcloudResource artifacts repositories describe $Repo --location $Region --project $ProjectId) -ne 0) {
    Invoke-Gcloud artifacts repositories create $Repo `
        --repository-format=docker `
        --location=$Region `
        --description="AI Facebook News Agent images" `
        --project $ProjectId | Out-Null
} else {
    Write-Host "    repo already exists"
}

# ------------------------------------------------------------------
# 3. Service account + IAM
# ------------------------------------------------------------------
Write-Step "Ensuring runtime service account $SaEmail"
if ((Test-GcloudResource iam service-accounts describe $SaEmail --project $ProjectId) -ne 0) {
    Invoke-Gcloud iam service-accounts create $SaName `
        --display-name="AI Facebook News Agent runner" `
        --project $ProjectId | Out-Null
    Start-Sleep -Seconds 5
} else {
    Write-Host "    service account already exists"
}


# ------------------------------------------------------------------
# 4. Secrets in Secret Manager
# ------------------------------------------------------------------
function Set-GcpSecret([string]$name, [string]$value) {
    $tmp = New-TemporaryFile
    try {
        # Write without a trailing newline so the secret matches exactly.
        [System.IO.File]::WriteAllText($tmp.FullName, $value)
        if ((Test-GcloudResource secrets describe $name --project $ProjectId) -ne 0) {
            Invoke-Gcloud secrets create $name --data-file=$($tmp.FullName) --replication-policy=automatic --project $ProjectId | Out-Null
            Write-Host "    created secret $name"
        } else {
            Invoke-Gcloud secrets versions add $name --data-file=$($tmp.FullName) --project $ProjectId | Out-Null
            Write-Host "    updated secret $name"
        }
    } finally {
        Remove-Item $tmp.FullName -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Syncing secrets from .env into Secret Manager"
Set-GcpSecret "AI_API_KEY" $AiApiKeyValue
Set-GcpSecret "NEWS_API_KEY" $NewsApiKeyValue
Set-GcpSecret "FACEBOOK_PAGE_ACCESS_TOKEN" $FbTokenValue
Set-GcpSecret "DATABASE_URL" $DatabaseUrlValue

foreach ($secret in @("AI_API_KEY", "NEWS_API_KEY", "FACEBOOK_PAGE_ACCESS_TOKEN", "DATABASE_URL")) {
    Invoke-Gcloud secrets add-iam-policy-binding $secret `
        --member="serviceAccount:$SaEmail" `
        --role="roles/secretmanager.secretAccessor" `
        --project $ProjectId | Out-Null
}

# ------------------------------------------------------------------
# 5. Build + push the image (Cloud Build; no local Docker needed)
# ------------------------------------------------------------------
Write-Step "Building and pushing the image"
Invoke-Gcloud builds submit `
    --config cloudbuild.yaml `
    --substitutions="_REGION=$Region,_REPO=$Repo,_IMAGE=$Image,_TAG=$Tag" `
    --project $ProjectId `
    "." | Out-Null

# ------------------------------------------------------------------
# 6. Cloud Run Job (stateless; Neon connection + secrets)
# ------------------------------------------------------------------
$RunSecrets = "AI_API_KEY=AI_API_KEY:latest,NEWS_API_KEY=NEWS_API_KEY:latest,FACEBOOK_PAGE_ACCESS_TOKEN=FACEBOOK_PAGE_ACCESS_TOKEN:latest,DATABASE_URL=DATABASE_URL:latest"

# Use a temp YAML file for env vars because values may contain commas,
# which conflict with the comma delimiter of --set-env-vars.
# --env-vars-file expects YAML map syntax (KEY: "value"), not KEY=VALUE.
function ConvertTo-YamlValue([string]$v) {
    return $v.Replace('\', '\\').Replace('"', '\"')
}
$EnvVarsFile = [System.IO.Path]::GetTempFileName()
@(
    "AI_PROVIDER: `"$(ConvertTo-YamlValue $AiProviderVal)`"",
    "AI_MODEL: `"$(ConvertTo-YamlValue $AiModelVal)`"",
    "AI_BASE_URL: `"$(ConvertTo-YamlValue $AiBaseUrlVal)`"",
    "NEWS_PROVIDER: `"$(ConvertTo-YamlValue $NewsProviderVal)`"",
    "NEWS_LANGUAGE: `"$(ConvertTo-YamlValue $NewsLanguageVal)`"",
    "MAX_CANDIDATES: `"$(ConvertTo-YamlValue $MaxCandidatesVal)`"",
    "NEWS_LOOKBACK_HOURS: `"$(ConvertTo-YamlValue $NewsLookbackVal)`"",
    "MAX_POST_CHARS: `"$(ConvertTo-YamlValue $MaxPostCharsVal)`"",
    "DRY_RUN: `"$(ConvertTo-YamlValue $DryRun)`"",
    "MIN_POST_INTERVAL_HOURS: `"$(ConvertTo-YamlValue $MinPostIntervalVal)`"",
    "POST_TIMES: `"$(ConvertTo-YamlValue $PostTimesVal)`"",
    "POST_TIMEZONE: `"$(ConvertTo-YamlValue $PostTimezoneVal)`"",
    "POST_TONE: `"$(ConvertTo-YamlValue $PostToneVal)`"",

    "FACEBOOK_PAGE_ID: `"$(ConvertTo-YamlValue $FbPageIdVal)`"",
    "RSS_FEEDS: `"$(ConvertTo-YamlValue $RssFeedsVal)`""
) | Set-Content -Path $EnvVarsFile -Encoding UTF8

Write-Step "Ensuring Cloud Run Job '$JobName'"
if ((Test-GcloudResource run jobs describe $JobName --region $Region --project $ProjectId) -eq 0) {
    Invoke-Gcloud run jobs update $JobName `
        --image $ImageUri `
        --region $Region `
        --project $ProjectId `
        --service-account $SaEmail `
        --set-secrets $RunSecrets `
        --env-vars-file $EnvVarsFile `
        --tasks 1 `
        --max-retries $MaxRetries `
        --task-timeout $TaskTimeout | Out-Null
} else {
    Invoke-Gcloud run jobs create $JobName `
        --image $ImageUri `
        --region $Region `
        --project $ProjectId `
        --service-account $SaEmail `
        --set-secrets $RunSecrets `
        --env-vars-file $EnvVarsFile `
        --tasks 1 `
        --max-retries $MaxRetries `
        --task-timeout $TaskTimeout | Out-Null
}
Remove-Item -Path $EnvVarsFile -Force

# ------------------------------------------------------------------
# 7. Cloud Scheduler trigger
# ------------------------------------------------------------------
$ProjectNumber = (Get-GcloudOutput projects describe $ProjectId --format="value(projectNumber)" | Select-Object -First 1)
$ProjectNumber = "$ProjectNumber".Trim()
$SchedulerSa = "$ProjectNumber-compute@developer.gserviceaccount.com"
$JobUri = "https://$Region-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$ProjectId/jobs/${JobName}:run"

Write-Step "Ensuring Cloud Scheduler job '$SchedulerName' ($Schedule in $SchedulerTimeZone)"
if ((Test-GcloudResource scheduler jobs describe $SchedulerName --location $Region --project $ProjectId) -eq 0) {
    Invoke-Gcloud scheduler jobs update http $SchedulerName `
        --location $Region `
        --project $ProjectId `
        --schedule $Schedule `
        --time-zone $SchedulerTimeZone `
        --uri $JobUri `
        --http-method POST `
        --oauth-service-account-email $SchedulerSa | Out-Null
} else {
    Invoke-Gcloud scheduler jobs create http $SchedulerName `
        --location $Region `
        --project $ProjectId `
        --schedule $Schedule `
        --time-zone $SchedulerTimeZone `
        --uri $JobUri `
        --http-method POST `
        --oauth-service-account-email $SchedulerSa | Out-Null
}

if ((Test-GcloudResource run jobs add-iam-policy-binding $JobName `
        --region $Region `
        --project $ProjectId `
        --member="serviceAccount:$SchedulerSa" `
        --role="roles/run.developer") -ne 0) {
    Write-Warn2 "Could not add run.developer to $SchedulerSa; grant it manually if executions fail."
}
Invoke-Gcloud iam service-accounts add-iam-policy-binding $SchedulerSa `
    --member="serviceAccount:$SchedulerSa" `
    --role="roles/iam.serviceAccountUser" `
    --project $ProjectId | Out-Null

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
Write-Step "Deployment complete"
Write-Host @"

Project:      $ProjectId
Region:       $Region
Image:        $ImageUri
History:      Neon (DATABASE_URL secret)
Job:          $JobName
Scheduler:    $SchedulerName  ($Schedule in $SchedulerTimeZone)

Next steps:
  1) Run the job once manually to test (DRY_RUN=$DryRun):
       gcloud run jobs execute $JobName --region $Region --project $ProjectId --wait

  2) Read the logs:
       gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=$JobName" --limit 50 --project $ProjectId --format "value(textPayload)"

  3) When the dry run looks good, post for real:
       gcloud run jobs update $JobName --region $Region --project $ProjectId --update-env-vars DRY_RUN=false

  4) Reset posting history (if needed):
       gcloud run jobs execute $JobName --region $Region --project $ProjectId --args=--clear-history --wait
"@

