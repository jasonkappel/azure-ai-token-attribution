<#
=============================================================================
 Portal - query-helper: build portal/data.json from live Log Analytics data
-----------------------------------------------------------------------------
 WHAT THIS DOES
   Reads config.json, builds a per-record dataset for the portal and writes portal/data.json.
   It prefers the ENRICHMENT custom table (department / app / user + all token meters); if that
   table is not wired, it falls back to the platform diagnostic log (Pattern A) and the gateway
   LLM log (Pattern B), attributing per principal (no dept/app/user). Costs come from the shared
   metering module so the portal and the acceptance test price identically.

 PREREQUISITES
   - Azure CLI signed in (`az login`) with read access to the workspace.
   - config.json exists (copy config.sample.json). Values you supply:
       workspaceId     -> the Log Analytics workspace GUID (customerId).
       timeRangeHours  -> lookback window in hours (e.g. 168 = 7 days).
       rateCardCsv     -> path to your effective-dated rate card CSV.
       enrichmentTable -> (optional) custom-table name; defaults to AiSpendEnrichment_CL.
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

# Thin field reader used by the pricing calls, null-safe on rows that lack optional meters or that
# carry a non-numeric placeholder (e.g. "None") from a mixed-vintage table.
function Get-Field($r, $n) {
  if (-not ($r.PSObject.Properties[$n])) { return [long]0 }
  $v = $r.$n
  if ($null -eq $v) { return [long]0 }
  $out = [long]0
  if ([long]::TryParse([string]$v, [ref]$out)) { return $out } else { return [long]0 }
}
# =============================================================================
#  The portal is a per-record view (Overview / Azure OpenAI / Claude / By user, with
#  department -> app -> user drill-down). It is driven by ONE records[] array. We build it
#  from the ENRICHMENT table if it is wired (full dept/app/user + all meters), else we fall
#  back to the platform diagnostic log + gateway LLM log (per-principal; dept/app/user unknown).
# =============================================================================
$enrichTable = if ($cfg.PSObject.Properties['enrichmentTable'] -and $cfg.enrichmentTable) { [string]$cfg.enrichmentTable } else { 'AiSpendEnrichment_CL' }

# Price one ENRICHMENT record. The enrichment table stores input in the ALREADY-UNCACHED convention
# for both families, so AOAI is priced by reconstructing the inclusive prompt (uncached + cached-read).
function Price-Enrichment($r) {
  $inp = Get-Field $r 'inputTokens'; $out = Get-Field $r 'outputTokens'
  $cw  = Get-Field $r 'cacheWriteTokens'; $cr = Get-Field $r 'cacheReadTokens'
  if ($r.pipeline -eq 'gateway') {
    return Get-ClaudeCost -Rates $rates -Model $r.model -InputTokens $inp -OutputTokens $out -CacheCreationTotal $cw -CacheRead $cr
  } else {
    return Get-AoaiCost -Rates $rates -Model $r.model -PromptTokens ($inp + $cr) -CachedTokens $cr -CompletionTokens $out
  }
}

$records = New-Object System.Collections.Generic.List[object]
$source = $null; $queryOk = $true

# ---- Primary: the enrichment custom table (per record, all dimensions + all meters). ----
Write-Host "Querying enrichment table ($enrichTable)..."
$enrichKql = @"
$enrichTable
| where TimeGenerated > ago(${hours}h)
| project TimeGenerated, oid, userName, department, app, pipeline, model,
          inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, thinkingTokens
| take 20000
"@
$enrichRes = Invoke-Kql $enrichKql
if ($enrichRes.ok -and $enrichRes.rows.Count -gt 0) {
  $source = 'enrichment'
  foreach ($r in $enrichRes.rows) {
    $pipeline = if ($r.pipeline -eq 'gateway') { 'gateway' } else { 'aoai' }
    $price = Price-Enrichment $r
    $iv = if ($pipeline -eq 'gateway') {
      Test-UsageIntegrity -Family 'claude' -OutputTokens (Get-Field $r 'outputTokens') -ThinkingTokens (Get-Field $r 'thinkingTokens')
    } else {
      Test-UsageIntegrity -Family 'aoai' -PromptTokens ((Get-Field $r 'inputTokens') + (Get-Field $r 'cacheReadTokens')) -CachedTokens (Get-Field $r 'cacheReadTokens')
    }
    if ($iv.Count) { Write-Warning ("integrity oid=$($r.oid) model=$($r.model): " + ($iv -join '; ')) }
    # Per family: AOAI has no per-user cache-write/thinking on this store -> null (renders n/a/dash).
    $isGw = ($pipeline -eq 'gateway')
    $records.Add([ordered]@{
      ts = $r.TimeGenerated; oid = $r.oid; user = $r.userName; department = $r.department; app = $r.app
      pipeline = $pipeline; model = $r.model
      input = [long](Get-Field $r 'inputTokens'); output = [long](Get-Field $r 'outputTokens')
      cacheWrite = if ($isGw) { [long](Get-Field $r 'cacheWriteTokens') } else { $null }
      cacheRead  = [long](Get-Field $r 'cacheReadTokens')
      thinking   = if ($isGw) { [long](Get-Field $r 'thinkingTokens') } else { $null }
      cost = if ($null -eq $price) { $null } else { [Math]::Round($price, 6) }
      costBasis = if ($null -eq $price) { 'unpriced' } elseif ($isGw) { 'full' } else { 'full' }
    })
  }
} else {
  # ---- Fallback: platform diagnostic log (Pattern A) + gateway LLM log (Pattern B), per call. ----
  $source = 'platform-log'
  Write-Host "Enrichment table not wired/empty - falling back to platform + gateway logs (per-principal, no dept/app/user)."

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
| project TimeGenerated, oid, model, deployment, promptTokens, completionTokens, cachedInput
| take 5000
"@
  Write-Host "Querying Azure OpenAI platform log (Pattern A)..."
  $aoaiRes = Invoke-Kql $aoaiKql
  if (-not $aoaiRes.ok) { $queryOk = $false }
  foreach ($r in $aoaiRes.rows) {
    $prompt = [long](Get-Field $r 'promptTokens'); $cached = [long](Get-Field $r 'cachedInput'); $comp = [long](Get-Field $r 'completionTokens')
    $price = Get-AoaiCost -Rates $rates -Model $r.model -PromptTokens $prompt -CachedTokens $cached -CompletionTokens $comp
    $iv = Test-UsageIntegrity -Family 'aoai' -PromptTokens $prompt -CachedTokens $cached
    if ($iv.Count) { Write-Warning ("AOAI integrity oid=$($r.oid) model=$($r.model): " + ($iv -join '; ')) }
    $records.Add([ordered]@{
      ts = $r.TimeGenerated; oid = $r.oid; user = $null
      department = '(unattributed)'; app = $r.deployment; pipeline = 'aoai'; model = $r.model
      input = [Math]::Max($prompt - $cached, 0); output = $comp
      cacheWrite = $null; cacheRead = $cached; thinking = $null
      cost = if ($null -eq $price) { $null } else { [Math]::Round($price, 6) }
      costBasis = if ($null -eq $price) { 'unpriced' } else { 'full' }
    })
  }

  $claudeKql = @"
let idByCorrelation = ApiManagementGatewayLogs
    | where TimeGenerated > ago(${hours}h)
    | where isnotempty(CorrelationId)
    | extend oid = tostring(parse_json(tostring(RequestHeaders))['x-caller-oid'])
    | where isnotempty(oid)
    | project CorrelationId, oid;
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(${hours}h)
| project TimeGenerated, CorrelationId, model = tostring(DeploymentName),
          promptTokens = tolong(PromptTokens), completionTokens = tolong(CompletionTokens)
| join kind=leftouter idByCorrelation on CorrelationId
| project TimeGenerated, oid = coalesce(oid, 'unattributed'), model, promptTokens, completionTokens
| take 5000
"@
  Write-Host "Querying Claude gateway LLM log (Pattern B)..."
  $claudeRes = Invoke-Kql $claudeKql
  # A missing gateway table is expected when Pattern B is not wired - do NOT flip queryOk for that.
  foreach ($r in $claudeRes.rows) {
    $prompt = [long](Get-Field $r 'promptTokens'); $comp = [long](Get-Field $r 'completionTokens')
    $price = Get-ClaudeCost -Rates $rates -Model $r.model -InputTokens $prompt -OutputTokens $comp
    $records.Add([ordered]@{
      ts = $r.TimeGenerated; oid = $r.oid; user = $null
      department = '(unattributed)'; app = $r.model; pipeline = 'gateway'; model = $r.model
      input = $prompt; output = $comp
      cacheWrite = $null; cacheRead = $null; thinking = $null   # per-user cache not captured at the gateway on streaming
      cost = if ($null -eq $price) { $null } else { [Math]::Round($price, 6) }
      costBasis = if ($null -eq $price) { 'unpriced' } else { 'p+c-only' }
    })
  }
}

$data = [ordered]@{
  generatedAt    = (Get-Date).ToUniversalTime().ToString("o")
  timeRangeHours = $hours
  source         = $source          # "enrichment" | "platform-log"
  queryOk        = $queryOk         # false => a query FAILED (portal shows a failure banner, not $0)
  records        = $records
}

$data | ConvertTo-Json -Depth 8 | Set-Content -Path $OutPath -Encoding utf8
Write-Host "Wrote $OutPath  (source=$source, records=$($records.Count), queryOk=$queryOk)"
Write-Host "Open portal/index.html to view. If there are 0 records, the portal shows 'Not configured'."
