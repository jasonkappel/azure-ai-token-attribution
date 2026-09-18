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
    $col = { param($n) if ($_.PSObject.Properties[$n] -and $_.$n) { [double]$_.$n } else { 0 } }
    $rates[$_.model] = @{
      input      = [double]$_.input_per_1m
      cached     = (& $col 'cached_input_per_1m')     # AOAI cached-read discount
      output     = [double]$_.output_per_1m
      cacheW5m   = (& $col 'cache_write_5m_per_1m')    # Claude 5m cache write (~1.25x)
      cacheW1h   = (& $col 'cache_write_1h_per_1m')    # Claude 1h cache write (~2x)
      cacheRead  = (& $col 'cache_read_per_1m')        # Claude cache read (~0.1x)
    }
  }
} else {
  Write-Warning "Rate card CSV not found ($rateCsv). Costs will be 0. Set rateCardCsv in config.json."
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

function Price-Aoai($r) {
  # Two-algebra rule (AOAI): prompt_tokens INCLUDES cached_tokens, so billable input = prompt - cached.
  # Reasoning tokens are a subset of completion and are already priced inside output - never add them.
  # Returns $null (UNPRICED) when the model has no rate row - do NOT report unknown price as $0.
  $rc = $rates[$r.model]; if (-not $rc) { return $null }
  $prompt = [double]$r.promptTokens; $cached = [double]$r.cachedInput; $comp = [double]$r.completionTokens
  $billable = [Math]::Max($prompt - $cached, 0)
  return ($billable*$rc.input + $cached*$rc.cached + $comp*$rc.output) / 1000000.0
}
function Price-Claude($r) {
  # Two-algebra rule (Claude): input_tokens is ALREADY uncached (exclusive of cache meters), so ADD the
  # meters - never subtract. Cache write has 5m/1h tiers priced differently. thinking_tokens are a subset
  # of output (already in completionTokens) and are NEVER added. The per-user gateway (streaming) path
  # carries only prompt+completion; the extra meters are absent and this reduces to prompt+completion.
  # Returns $null (UNPRICED) when the model has no rate row.
  $rc = $rates[$r.model]; if (-not $rc) { return $null }
  $g = { param($n) if ($r.PSObject.Properties[$n] -and $r.$n) { [double]$r.$n } else { 0 } }
  $w5 = (& $g 'cacheWrite5m'); $w1 = (& $g 'cacheWrite1h')
  # Partial-capture guard: if only the scalar total write is present (no 5m/1h split), price it at the
  # 5m rate rather than silently billing the write at $0. Never let a captured write cost nothing.
  if ($w5 -eq 0 -and $w1 -eq 0) { $w5 = (& $g 'cacheCreation') }
  return ( [double]$r.promptTokens*$rc.input + [double]$r.completionTokens*$rc.output `
         + $w5*$rc.cacheW5m + $w1*$rc.cacheW1h + (& $g 'cacheRead')*$rc.cacheRead ) / 1000000.0
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
$aoaiRes = Invoke-Kql $aoaiKql
$aoaiRows = @($aoaiRes.rows | ForEach-Object {
  $price = Price-Aoai $_
  [pscustomobject]@{
    oid = $_.oid; model = $_.model; deployment = $_.deployment
    calls = [int]$_.calls; promptTokens = [long]$_.promptTokens
    completionTokens = [long]$_.completionTokens; cachedInput = [long]$_.cachedInput
    # null (UNPRICED) stays null so the portal renders it as an em-dash, never a false $0.
    estCostUsd = if ($null -eq $price) { $null } else { [Math]::Round($price, 6) }
    costBasis  = if ($null -eq $price) { "unpriced" } else { "full" }   # AOAI cached is captured in the log
  }
})

Write-Host "Querying Claude gateway (Pattern B)..."
$claudeRes = Invoke-Kql $claudeKql
$claudeRows = @($claudeRes.rows | ForEach-Object {
  $price = Price-Claude $_
  [pscustomobject]@{
    oid = $_.oid; model = $_.model
    calls = [int]$_.calls; promptTokens = [long]$_.promptTokens
    completionTokens = [long]$_.completionTokens
    estCostUsd = if ($null -eq $price) { $null } else { [Math]::Round($price, 6) }
    costBasis  = Get-ClaudeBasis $_ $price   # "full" | "p+c-only" (streaming) | "unpriced"
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
