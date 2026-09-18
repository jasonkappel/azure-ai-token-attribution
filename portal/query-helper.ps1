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

# ---- Import the shared metering module (the ONE cost-model implementation). ----
Import-Module (Join-Path $PSScriptRoot '..\lib\AiBilling.Metering.psm1') -Force

# ---- Load the rate card into a per-model lookup (USD per 1,000,000 tokens). ----
if ($rateCsv -and (Test-Path $rateCsv)) {
  $rates = Import-RateCard -Path $rateCsv
} else {
  $rates = @{}
  Write-Warning "Rate card CSV not found ($rateCsv). Costs will be UNPRICED (null). Set rateCardCsv in config.json."
}

function Invoke-Kql([string]$query) {
  # Runs the query from a BOM-less temp file. Returns a hashtable so callers can tell three
  # states apart: ok+rows, ok+empty (pattern not wired), and FAILED (bad query / missing table /
  # no access). A failure must NOT look like zero spend, so we surface it instead of returning [].
  $tmp = New-TemporaryFile
  [System.IO.File]::WriteAllText($tmp, $query, (New-Object System.Text.UTF8Encoding($false)))
  try {
    $json = az monitor log-analytics query --workspace $workspaceId --analytics-query "@$tmp" -o json 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warning "KQL query FAILED (exit $LASTEXITCODE) - treating as failed, NOT zero spend."; return @{ ok = $false; rows = @() } }
    if ([string]::IsNullOrWhiteSpace($json)) { return @{ ok = $true; rows = @() } }
    return @{ ok = $true; rows = @($json | ConvertFrom-Json) }
  } catch { Write-Warning "KQL query threw: $($_.Exception.Message) - treating as failed, NOT zero spend."; return @{ ok = $false; rows = @() } }
  finally { Remove-Item $tmp -Force }
}

# Thin row-adapters over the shared cost model, so the portal and the acceptance test price
# identically. Defensive field reads keep them null-safe on rows that lack the optional meters.
function Get-Field($r, $n) { if ($r.PSObject.Properties[$n] -and $r.$n) { return [long]$r.$n } else { return 0 } }
function Price-Aoai($r) {
  return Get-AoaiCost -Rates $rates -Model $r.model `
    -PromptTokens (Get-Field $r 'promptTokens') -CachedTokens (Get-Field $r 'cachedInput') `
    -CompletionTokens (Get-Field $r 'completionTokens')
}
function Price-Claude($r) {
  return Get-ClaudeCost -Rates $rates -Model $r.model `
    -InputTokens (Get-Field $r 'promptTokens') -OutputTokens (Get-Field $r 'completionTokens') `
    -CacheWrite5m (Get-Field $r 'cacheWrite5m') -CacheWrite1h (Get-Field $r 'cacheWrite1h') `
    -CacheRead (Get-Field $r 'cacheRead') -CacheCreationTotal (Get-Field $r 'cacheCreation')
}
# costBasis labels the fidelity of each row's estimate so the portal never shows a confident dollar
# that silently omitted cache. "full" = cache/thinking meters present; "p+c-only" = prompt+completion
# only (the streaming gateway path); "unpriced" = no rate row for the model.
function Get-ClaudeBasis($r, $price) {
  if ($null -eq $price) { return "unpriced" }
  $hasCache = ($r.PSObject.Properties['cacheWrite5m'] -and $r.cacheWrite5m) -or `
              ($r.PSObject.Properties['cacheWrite1h'] -and $r.cacheWrite1h) -or `
              ($r.PSObject.Properties['cacheRead'] -and $r.cacheRead) -or `
              ($r.PSObject.Properties['cacheCreation'] -and $r.cacheCreation)
  if ($hasCache) { "full" } else { "p+c-only" }
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
| extend cachedInput = coalesce(usageCached, long(0))
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
$aoaiRes = Invoke-Kql $aoaiKql
$aoaiRows = @($aoaiRes.rows | ForEach-Object {
  $price = Price-Aoai $_
  # Wire the integrity gates into the pipeline so they are not decorative: a row whose meters
  # violate an invariant (cached > prompt) is surfaced, not silently priced.
  $iv = Test-UsageIntegrity -Family 'aoai' -PromptTokens (Get-Field $_ 'promptTokens') -CachedTokens (Get-Field $_ 'cachedInput')
  if ($iv.Count) { Write-Warning ("AOAI integrity oid=$($_.oid) model=$($_.model): " + ($iv -join '; ')) }
  [pscustomobject]@{
    oid = $_.oid; model = $_.model; deployment = $_.deployment
    calls = [int]$_.calls; promptTokens = [long]$_.promptTokens
    completionTokens = [long]$_.completionTokens; cachedInput = [long]$_.cachedInput
    # null (UNPRICED) stays null so the portal renders it as an em-dash, never a false $0.
    estCostUsd = if ($null -eq $price) { $null } else { [Math]::Round($price, 6) }
    costBasis  = if ($null -eq $price) { "unpriced" } else { "full" }   # AOAI cached is captured in the log
    integrity  = if ($iv.Count) { ($iv -join '; ') } else { "ok" }
  }
})

Write-Host "Querying Claude gateway (Pattern B)..."
$claudeRes = Invoke-Kql $claudeKql
$claudeRows = @($claudeRes.rows | ForEach-Object {
  $price = Price-Claude $_
  $iv = Test-UsageIntegrity -Family 'claude' -OutputTokens (Get-Field $_ 'completionTokens') `
        -ThinkingTokens (Get-Field $_ 'thinking') -CacheCreationTotal (Get-Field $_ 'cacheCreation') `
        -CacheWrite5m (Get-Field $_ 'cacheWrite5m') -CacheWrite1h (Get-Field $_ 'cacheWrite1h')
  if ($iv.Count) { Write-Warning ("Claude integrity oid=$($_.oid) model=$($_.model): " + ($iv -join '; ')) }
  [pscustomobject]@{
    oid = $_.oid; model = $_.model
    calls = [int]$_.calls; promptTokens = [long]$_.promptTokens
    completionTokens = [long]$_.completionTokens
    estCostUsd = if ($null -eq $price) { $null } else { [Math]::Round($price, 6) }
    costBasis  = Get-ClaudeBasis $_ $price   # "full" | "p+c-only" (streaming) | "unpriced"
    integrity  = if ($iv.Count) { ($iv -join '; ') } else { "ok" }
  }
})

$data = [ordered]@{
  generatedAt    = (Get-Date).ToUniversalTime().ToString("o")
  timeRangeHours = $hours
  # queryOk flags let the portal distinguish a FAILED query from a genuinely empty result
  # (a failure must not read as zero spend).
  aoai   = @{ rows = $aoaiRows;   queryOk = $aoaiRes.ok }
  claude = @{ rows = $claudeRows; queryOk = $claudeRes.ok }
}

$data | ConvertTo-Json -Depth 8 | Set-Content -Path $OutPath -Encoding utf8
Write-Host "Wrote $OutPath  (aoai rows=$($aoaiRows.Count), claude rows=$($claudeRows.Count))"
Write-Host "Open portal/index.html to view. If both patterns returned 0 rows, the portal shows 'Not configured'."
