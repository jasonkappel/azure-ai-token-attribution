<#
=============================================================================
 Portal - query-helper: build portal/data.json from live Log Analytics data
-----------------------------------------------------------------------------
 WHAT THIS DOES
   Reads config.json, runs the Pattern A (Azure OpenAI, no gateway) and Pattern B
   (Claude via gateway) attribution queries against your Log Analytics workspace,
   prices each row with your rate card, and writes portal/data.json. The portal
   (index.html) renders whatever is present; a pattern you have not wired up simply
   returns no rows and its section stays empty.

 PREREQUISITES
   - Azure CLI signed in (`az login`) with read access to the workspace.
   - config.json exists (copy config.sample.json). Every value you supply:
       workspaceId    -> the Log Analytics workspace GUID (customerId).
       timeRangeHours -> lookback window in hours (e.g. 168 = 7 days).
       rateCardCsv    -> path to your effective-dated rate card CSV.
   - The rate card CSV columns match aoai-no-gateway/03-pricing-table.sample.csv:
       model,deployment_type,region,currency,input_per_1m,cached_input_per_1m,output_per_1m,...
   - data.json is git-ignored on purpose. It holds live identity data; never commit it.
=============================================================================
#>

param(
  [string]$ConfigPath = "$PSScriptRoot/config.json",
  [string]$OutPath    = "$PSScriptRoot/data.json"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
  throw "No config.json found. Copy config.sample.json to config.json and fill in your values."
}
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$workspaceId = $cfg.workspaceId          # YOU SUPPLY: workspace GUID
$hours       = [int]$cfg.timeRangeHours  # YOU SUPPLY: lookback in hours
$rateCsv     = $cfg.rateCardCsv          # YOU SUPPLY: path to rate card CSV
if ($rateCsv -and -not [System.IO.Path]::IsPathRooted($rateCsv)) {
  $rateCsv = Join-Path $PSScriptRoot $rateCsv
}

# ---- Load the rate card into a per-model lookup (USD per 1,000,000 tokens). ----
$rates = @{}
if ($rateCsv -and (Test-Path $rateCsv)) {
  Import-Csv $rateCsv | Where-Object { $_.model -and $_.model -notmatch '^\s*#' } | ForEach-Object {
    $cachedRate = if ($_.PSObject.Properties['cached_input_per_1m'] -and $_.cached_input_per_1m) { [double]$_.cached_input_per_1m } else { 0 }
    $rates[$_.model] = @{
      input  = [double]$_.input_per_1m
      cached = $cachedRate
      output = [double]$_.output_per_1m
    }
  }
} else {
  Write-Warning "Rate card CSV not found ($rateCsv). Costs will be 0. Set rateCardCsv in config.json."
}

function Invoke-Kql([string]$query) {
  # Writes the query to a BOM-less temp file and runs it. Returns [] on any failure
  # (e.g. a table that does not exist because that pattern is not wired up yet).
  $tmp = New-TemporaryFile
  [System.IO.File]::WriteAllText($tmp, $query, (New-Object System.Text.UTF8Encoding($false)))
  try {
    $json = az monitor log-analytics query --workspace $workspaceId --analytics-query "@$tmp" -o json 2>$null
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }
    return ($json | ConvertFrom-Json)
  } catch { return @() } finally { Remove-Item $tmp -Force }
}

function Price-Aoai($r) {
  $rc = $rates[$r.model]; if (-not $rc) { return 0 }
  $prompt = [double]$r.promptTokens; $cached = [double]$r.cachedInput; $comp = [double]$r.completionTokens
  $billable = [Math]::Max($prompt - $cached, 0)
  return ($billable*$rc.input + $cached*$rc.cached + $comp*$rc.output) / 1000000.0
}
function Price-Claude($r) {
  $rc = $rates[$r.model]; if (-not $rc) { return 0 }
  return ([double]$r.promptTokens*$rc.input + [double]$r.completionTokens*$rc.output) / 1000000.0
}

# ---- Pattern A: Azure OpenAI per caller x model x deployment (with cached subset). ----
$aoaiKql = @"
let usage = AzureDiagnostics
    | where TimeGenerated > ago(${hours}h)
    | where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES'
    | where Category == 'AzureOpenAIRequestUsage'
    | extend up = parse_json(properties_s)
    | project CorrelationId, usageCached = tolong(up.cachedTokens[0]);
AzureDiagnostics
| where TimeGenerated > ago(${hours}h)
| where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES'
| where Category == 'RequestResponse' and event_s == 'ShoeboxCallResult'
| extend p = parse_json(properties_s)
| extend oid = tostring(p.callerObjectId)
| where isnotempty(oid)
| extend model = tostring(p.modelName), deployment = tostring(p.modelDeploymentName),
         promptTokens = tolong(p.promptTokens), completionTokens = tolong(p.completionTokens)
| join kind=leftouter usage on CorrelationId
| extend cachedInput = coalesce(usageCached, 0L)
| summarize calls = count(), promptTokens = sum(promptTokens),
            completionTokens = sum(completionTokens), cachedInput = sum(cachedInput)
          by oid, model, deployment
"@

# ---- Pattern B: Claude per caller x model (prompt+completion; cache is total-only). ----
$claudeKql = @"
let idByCorrelation = ApiManagementGatewayLogs
    | where TimeGenerated > ago(${hours}h)
    | where isnotempty(CorrelationId)
    | extend oid = tostring(parse_json(tostring(RequestHeaders))['x-caller-oid'])
    | where isnotempty(oid)
    | project CorrelationId, oid;
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(${hours}h)
| project CorrelationId, model = tostring(DeploymentName),
          promptTokens = tolong(PromptTokens), completionTokens = tolong(CompletionTokens)
| join kind=leftouter idByCorrelation on CorrelationId
| summarize calls = count(), promptTokens = sum(promptTokens), completionTokens = sum(completionTokens)
          by oid = coalesce(oid, 'unattributed'), model
"@

Write-Host "Querying Azure OpenAI (Pattern A)..."
$aoaiRows = @(Invoke-Kql $aoaiKql | ForEach-Object {
  [pscustomobject]@{
    oid = $_.oid; model = $_.model; deployment = $_.deployment
    calls = [int]$_.calls; promptTokens = [long]$_.promptTokens
    completionTokens = [long]$_.completionTokens; cachedInput = [long]$_.cachedInput
    estCostUsd = [Math]::Round((Price-Aoai $_), 6)
  }
})

Write-Host "Querying Claude gateway (Pattern B)..."
$claudeRows = @(Invoke-Kql $claudeKql | ForEach-Object {
  [pscustomobject]@{
    oid = $_.oid; model = $_.model
    calls = [int]$_.calls; promptTokens = [long]$_.promptTokens
    completionTokens = [long]$_.completionTokens
    estCostUsd = [Math]::Round((Price-Claude $_), 6)
  }
})

$data = [ordered]@{
  generatedAt    = (Get-Date).ToUniversalTime().ToString("o")
  timeRangeHours = $hours
  aoai   = @{ rows = $aoaiRows }
  claude = @{ rows = $claudeRows }
}

$data | ConvertTo-Json -Depth 8 | Set-Content -Path $OutPath -Encoding utf8
Write-Host "Wrote $OutPath  (aoai rows=$($aoaiRows.Count), claude rows=$($claudeRows.Count))"
Write-Host "Open portal/index.html to view. If both patterns returned 0 rows, the portal shows 'Not configured'."
