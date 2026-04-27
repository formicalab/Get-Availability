<#
.SYNOPSIS
  Timer-triggered function that runs get-availability.ps1 for the previous month.

.DESCRIPTION
  Triggered on a CRON schedule (default: 1st of every month at 06:00 UTC).
  Can also be started manually from the Azure Portal or via the Functions runtime API.

  Reads configuration from App Settings (environment variables):
    GETAVAIL_SUBSCRIPTIONS  - Comma-separated list of subscription names or IDs (required)
    GETAVAIL_KINDS          - Comma-separated resource kinds (default: vm,sql,storage,webapp)
    DCE_ENDPOINT            - Data Collection Endpoint URL (optional, enables ingestion)
    DCR_IMMUTABLE_ID        - Data Collection Rule immutable ID (optional, paired with DCE_ENDPOINT)
    SOURCE_WORKSPACE_ID     - Log Analytics workspace ID for Resource Health queries (optional)
    GETAVAIL_PARALLELISM    - Parallel thread count (optional, default: script default)
    GETAVAIL_BATCH          - Set to "true" to enable batch metrics API (optional)
    GETAVAIL_BATCH_SIZE     - Batch size when batch mode is enabled (optional)

  The get-availability.ps1 script lives at the function app root (next to host.json)
  and is deployed automatically by 'func azure functionapp publish'.
#>

param($Timer)

# Strict / fail fast
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

# ── Read configuration from App Settings ──────────────────────────────────────

$subscriptionsRaw = $env:GETAVAIL_SUBSCRIPTIONS
if ([string]::IsNullOrWhiteSpace($subscriptionsRaw)) {
    throw 'App Setting GETAVAIL_SUBSCRIPTIONS is required but not set.'
}
$subscriptions = @($subscriptionsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$kindsRaw = $env:GETAVAIL_KINDS
$kinds = if (-not [string]::IsNullOrWhiteSpace($kindsRaw)) {
    @($kindsRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} else {
    @('vm', 'sql', 'storage', 'webapp')
}

# Compute previous month in YYYYMM format
$previousMonth = (Get-Date).ToUniversalTime().AddMonths(-1).ToString('yyyyMM')

# ── Ensure Azure context ─────────────────────────────────────────────────────

try {
    $context = Get-AzContext
    if (-not $context -or -not $context.Account -or $context.Account.Id -eq 'NotLoggedIn') {
        Write-Warning 'No valid Azure context found. Attempting Identity-based login...'
        Disable-AzContextAutosave -Scope Process | Out-Null
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Information 'Identity-based login succeeded.'
    } else {
        Write-Information "Using existing Azure context: $($context.Account.Id)"
    }
} catch {
    throw "Failed to verify or establish Azure login context: $_"
}

# ── Build script arguments ────────────────────────────────────────────────────

$scriptPath = Join-Path $PSScriptRoot '..' 'get-availability.ps1'
if (-not (Test-Path $scriptPath)) {
    throw "get-availability.ps1 not found at expected path: $scriptPath"
}

$scriptArgs = @{
    Subscriptions = $subscriptions
    Month         = $previousMonth
    Kinds         = $kinds
}

# Optional: Log Analytics ingestion
if (-not [string]::IsNullOrWhiteSpace($env:DCE_ENDPOINT) -and -not [string]::IsNullOrWhiteSpace($env:DCR_IMMUTABLE_ID)) {
    $scriptArgs['DceEndpoint']    = $env:DCE_ENDPOINT
    $scriptArgs['DcrImmutableId'] = $env:DCR_IMMUTABLE_ID
}

# Optional: Source workspace for Resource Health
if (-not [string]::IsNullOrWhiteSpace($env:SOURCE_WORKSPACE_ID)) {
    $scriptArgs['SourceWorkspaceId'] = $env:SOURCE_WORKSPACE_ID
}

# Optional: Parallelism
if (-not [string]::IsNullOrWhiteSpace($env:GETAVAIL_PARALLELISM)) {
    $scriptArgs['Parallelism'] = [int]$env:GETAVAIL_PARALLELISM
}

# Optional: Batch mode
if ($env:GETAVAIL_BATCH -eq 'true') {
    $scriptArgs['Batch'] = $true
    if (-not [string]::IsNullOrWhiteSpace($env:GETAVAIL_BATCH_SIZE)) {
        $scriptArgs['BatchSize'] = [int]$env:GETAVAIL_BATCH_SIZE
    }
}

# ── Execute ───────────────────────────────────────────────────────────────────

$timerStatus = if ($Timer.IsPastDue) { 'past due' } else { 'on time' }
Write-Information "GetAvail timer trigger fired ($timerStatus). Running for month $previousMonth with $($subscriptions.Count) subscription(s)."

& $scriptPath @scriptArgs

Write-Information "GetAvail completed for month $previousMonth."
