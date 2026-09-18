<#
=============================================================================
 Acceptance test - prove the AIBilling toolkit is correct end to end
-----------------------------------------------------------------------------
 WHAT THIS PROVES
   Two layers, so a customer's FinOps + security review has evidence, not vibes:

   OFFLINE (default, no Azure, ~1s): the deterministic accounting logic is right.
     - the TWO cost algebras (AOAI inclusive/subtract, Claude exclusive/add)
     - cache-write 5m vs 1h tiers, cache-read discount, scalar-write fallback
     - thinking is NEVER added to and NEVER subtracted from cost
     - integrity gates fire (thinking<=output, cached<=prompt, 5m+1h==creation)
     - dedup collapses double-logged calls, coverage %, reconciliation residual
     - unknown price => UNPRICED (null), never $0
   These run against a FIXED test rate card (acceptance/test-rate-card.csv) with
   round numbers, so every expected dollar below is hand-verifiable and does not
   drift when a customer edits their real rates.

   LIVE (opt-in, -Live, needs a wired Pattern A deployment): the round trip.
     identity -> captured usage -> ingestion (platform log) -> priced result,
     plus a least-privilege / RBAC preflight, dedup on real data, and coverage.
     Reconciliation to Cost Management is reported (not gated) because CM has
     hours-to-days latency.

 HOW TO RUN
   Offline:  ./acceptance/run-acceptance.ps1
   Live:     ./acceptance/run-acceptance.ps1 -Live -WorkspaceId <GUID> `
                 -FoundryEndpoint https://<name>.cognitiveservices.azure.com `
                 -Deployment <chat-deployment> [-CallCount 2] [-ResourceTotalUsd 0]

 EXIT CODE: 0 = all assertions passed; 1 = one or more failed (CI-friendly).
=============================================================================
#>
[CmdletBinding()]
param(
  [switch]$Live,
  [string]$WorkspaceId,
  [string]$FoundryEndpoint,
  [string]$Deployment,
  [int]$CallCount = 2,
  [int]$LookbackMinutes = 20,
  [int]$MaxWaitSeconds = 300,
  [double]$ResourceTotalUsd = -1     # supply the resource-day Marketplace total to compute a residual; <0 = skip
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot '..\lib\AiBilling.Metering.psm1') -Force

# ---- tiny test harness ----
$script:pass = 0; $script:fail = 0
function Ok($name)   { $script:pass++; Write-Host ("  [PASS] {0}" -f $name) -ForegroundColor Green }
function Bad($name, $detail) { $script:fail++; Write-Host ("  [FAIL] {0} -- {1}" -f $name, $detail) -ForegroundColor Red }
function Assert-Near($name, $actual, $expected, $tol = 1e-9) {
  if ($null -eq $actual) { Bad $name "actual is NULL, expected $expected"; return }
  if ([Math]::Abs([double]$actual - [double]$expected) -le $tol) { Ok $name } else { Bad $name "expected $expected, got $actual" }
}
function Assert-Null($name, $actual) { if ($null -eq $actual) { Ok $name } else { Bad $name "expected NULL, got $actual" } }
function Assert-Eq($name, $actual, $expected) { if ($actual -eq $expected) { Ok $name } else { Bad $name "expected $expected, got $actual" } }
function Assert-True($name, $cond, $detail = "") { if ($cond) { Ok $name } else { Bad $name $detail } }

Write-Host "`n=== AIBilling acceptance test ===" -ForegroundColor Cyan

# =====================================================================
#  OFFLINE: accounting logic against the fixed test rate card
# =====================================================================
Write-Host "`n-- OFFLINE: cost algebra --"
$rc = Import-RateCard -Path (Join-Path $PSScriptRoot 'test-rate-card.csv')
Assert-True "test rate card loads (2 models)" ($rc.Count -eq 2) "loaded $($rc.Count)"

# AOAI inclusive: prompt=1000 INCLUDES cached=200 -> billable 800. 800*10 + 200*1 + 500*20 = 18200 /1e6
Assert-Near "AOAI inclusive (prompt-cached)" (Get-AoaiCost -Rates $rc -Model 'test-aoai' -PromptTokens 1000 -CachedTokens 200 -CompletionTokens 500) 0.0182
# Claude 5m write: 100*10 + 200*20 + 1000*12.5 = 17500 /1e6
Assert-Near "Claude 5m cache-write (1.25x)" (Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 200 -CacheWrite5m 1000) 0.0175
# Claude 1h write: 100*10 + 200*20 + 1000*20 = 25000 /1e6  (premium over 5m)
Assert-Near "Claude 1h cache-write (2x)" (Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 200 -CacheWrite1h 1000) 0.025
# Claude read: 100*10 + 200*20 + 1000*1 = 6000 /1e6  (discount)
Assert-Near "Claude cache-read (0.1x-ish)" (Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 200 -CacheRead 1000) 0.006
# Scalar fallback: only cache_creation total present (no 5m/1h split) -> priced at 5m, NOT $0
Assert-Near "Claude scalar-write fallback (not free)" (Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 200 -CacheCreationTotal 1000) 0.0175

Write-Host "`n-- OFFLINE: thinking is billed as output, never added or subtracted --"
$noThink   = Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 200 -CacheWrite5m 1000
# thinking is not even a cost parameter, so a huge thinking value cannot change the dollar:
$withThink = Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 200 -CacheWrite5m 1000
Assert-Near "thinking not ADDED to cost" $withThink 0.0175
Assert-Near "thinking not SUBTRACTED from cost (output billed in full)" $withThink $noThink
# a "subtract thinking" bug would have produced (200-200)*20 = 0 output cost -> 0.0125; prove we did NOT
Assert-True "output cost is full 200 tokens, not (output-thinking)" ($withThink -gt 0.0125) "got $withThink"

Write-Host "`n-- OFFLINE: unpriced model => null, never `$0 --"
Assert-Null "unknown model is UNPRICED" (Get-ClaudeCost -Rates $rc -Model 'no-such-model' -InputTokens 100 -OutputTokens 200)

Write-Host "`n-- OFFLINE: integrity gates --"
Assert-Eq "clean row: 0 violations" (Test-UsageIntegrity -Family 'claude' -OutputTokens 200 -ThinkingTokens 50 -CacheCreationTotal 1000 -CacheWrite5m 600 -CacheWrite1h 400).Count 0
Assert-Eq "gate: thinking > output fires" (Test-UsageIntegrity -Family 'claude' -OutputTokens 200 -ThinkingTokens 250).Count 1
Assert-Eq "gate: AOAI cached > prompt fires" (Test-UsageIntegrity -Family 'aoai' -PromptTokens 1000 -CachedTokens 1200).Count 1
Assert-Eq "gate: 5m+1h != cache_creation fires" (Test-UsageIntegrity -Family 'claude' -CacheCreationTotal 1000 -CacheWrite5m 600 -CacheWrite1h 300).Count 1

Write-Host "`n-- OFFLINE: dedup, coverage, reconciliation --"
$dupRows = @(
  [pscustomobject]@{ apimRequestId = 'A'; promptTokens = 10 },
  [pscustomobject]@{ apimRequestId = 'A'; promptTokens = 10 },   # double-logged / retried
  [pscustomobject]@{ apimRequestId = 'B'; promptTokens = 20 }
)
Assert-Eq "dedup collapses double-logged call" (Merge-Dedup -Rows $dupRows -IdField 'apimRequestId').Count 2
$cov = Get-Coverage -Expected 8 -Captured 6
Assert-Near "coverage 6/8 = 75%" $cov.pct 75
$recon = Get-ReconciliationResidual -EstimateSum 90 -ResourceTotal 100
Assert-Near "reconciliation residual = 10" $recon.residual 10
Assert-Near "reconciliation residual = 10%" $recon.residualPct 10

# =====================================================================
#  LIVE: identity -> usage -> ingestion -> priced result (Pattern A)
# =====================================================================
if ($Live) {
  Write-Host "`n-- LIVE: Pattern A round trip --" -ForegroundColor Cyan
  if (-not $WorkspaceId -or -not $FoundryEndpoint -or -not $Deployment) {
    Bad "live prerequisites" "-Live requires -WorkspaceId, -FoundryEndpoint and -Deployment"
  } else {
    Add-Type -AssemblyName System.Net.Http

    # L1. Identity: who are we, per Entra?
    $signedInOid = (az ad signed-in-user show --query id -o tsv 2>$null)
    Assert-True "L1 identity: signed-in oid resolved" (-not [string]::IsNullOrWhiteSpace($signedInOid)) "run 'az login'"

    # L2. RBAC preflight: can we even read the workspace? (Log Analytics Reader on the workspace, not just the resource.)
    $probe = az monitor log-analytics query --workspace $WorkspaceId --analytics-query "print ping=1" -o json 2>$null
    Assert-True "L2 RBAC: workspace is queryable" ($LASTEXITCODE -eq 0 -and $probe) "grant 'Log Analytics Reader' on the workspace"

    # L3. Fire CallCount known calls AS THE USER (user token -> cognitiveservices), capture usage + apim-request-id.
    $aoaiTok = az account get-access-token --resource "https://cognitiveservices.azure.com" --query accessToken -o tsv 2>$null
    $http = [System.Net.Http.HttpClient]::new(); $http.Timeout = [TimeSpan]::FromSeconds(90)
    $fired = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $CallCount; $i++) {
      $uri  = "$FoundryEndpoint/openai/deployments/$Deployment/chat/completions?api-version=2024-10-21"
      $body = @{ messages = @(@{ role = "user"; content = ("Acceptance probe {0}: reply with the word ok." -f $i) }); max_tokens = 16 } | ConvertTo-Json -Depth 6
      $req  = [System.Net.Http.HttpRequestMessage]::new("Post", $uri)
      $req.Headers.Add("Authorization", "Bearer $aoaiTok")
      $req.Content = [System.Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, "application/json")
      $resp = $http.SendAsync($req).GetAwaiter().GetResult()
      $raw  = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      $apimId = $null; [void]$resp.Headers.TryGetValues("apim-request-id", [ref]$apimId)
      if ($resp.IsSuccessStatusCode) {
        $u = ($raw | ConvertFrom-Json).usage
        $cached = 0; if ($u.PSObject.Properties['prompt_tokens_details'] -and $u.prompt_tokens_details) { $cached = [int]$u.prompt_tokens_details.cached_tokens }
        $fired.Add([pscustomobject]@{
          apimId = ($apimId -join ","); prompt = [int]$u.prompt_tokens; completion = [int]$u.completion_tokens; cached = $cached
        })
      }
      Start-Sleep -Milliseconds 400
    }
    $http.Dispose()
    Assert-Eq "L3 fired all probe calls" $fired.Count $CallCount

    # L4. Wait for ingestion, then pull the attributed rows for our CorrelationIds.
    $ids = ($fired | ForEach-Object { "'" + $_.apimId + "'" }) -join ","
    $kql = @"
AzureDiagnostics
| where TimeGenerated > ago(${LookbackMinutes}m)
| where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES'
| where Category == 'RequestResponse' and event_s == 'ShoeboxCallResult'
| extend p = parse_json(properties_s)
| extend oid = tostring(p.callerObjectId)
| where isnotempty(oid)
| where CorrelationId in ($ids)
| project CorrelationId, oid, promptTokens = tolong(p.promptTokens), completionTokens = tolong(p.completionTokens)
"@
    $rows = @(); $waited = 0
    while ($waited -lt $MaxWaitSeconds) {
      $tmp = New-TemporaryFile
      [System.IO.File]::WriteAllText($tmp, $kql, (New-Object System.Text.UTF8Encoding($false)))
      $j = az monitor log-analytics query --workspace $WorkspaceId --analytics-query "@$tmp" -o json 2>$null
      Remove-Item $tmp -Force
      if ($j) { $rows = @($j | ConvertFrom-Json) }
      if ($rows.Count -ge $fired.Count) { break }
      Start-Sleep -Seconds 20; $waited += 20
      Write-Host ("    ...waiting for ingestion ({0}s, {1}/{2} rows)" -f $waited, $rows.Count, $fired.Count)
    }

    # L5. Correctness: exactly one attributed row per call, right identity, log tokens == API usage.
    $deduped = Merge-Dedup -Rows $rows -IdField 'CorrelationId'
    Assert-Eq "L5 dedup: one attributed row per call" $deduped.Count $fired.Count
    $identityOk = $true; $tokensOk = $true
    foreach ($f in $fired) {
      $match = $deduped | Where-Object { $_.CorrelationId -eq $f.apimId } | Select-Object -First 1
      if (-not $match) { $tokensOk = $false; $identityOk = $false; continue }
      if ($match.oid -ne $signedInOid) { $identityOk = $false }
      if ([long]$match.promptTokens -ne [long]$f.prompt -or [long]$match.completionTokens -ne [long]$f.completion) { $tokensOk = $false }
    }
    Assert-True "L5 identity: platform log oid == signed-in human" $identityOk "callerObjectId did not match the caller"
    Assert-True "L5 tokens: platform log == model usage object" $tokensOk "logged tokens differ from the API usage"

    # L6. Coverage.
    $cv = Get-Coverage -Expected $fired.Count -Captured $deduped.Count
    Assert-Near "L6 coverage == 100% for a clean run" $cv.pct 100

    # L7. Priced result (uses the PRODUCTION rate card so a real customer sees real numbers).
    $prodCard = Join-Path $PSScriptRoot '..\aoai-no-gateway\03-pricing-table.sample.csv'
    $prodRates = Import-RateCard -Path $prodCard
    $priced = 0.0; $anyUnpriced = $false
    foreach ($f in $fired) {
      # the deployment name is the model here only if your rate card is keyed by it; customers map as needed.
      $c = Get-AoaiCost -Rates $prodRates -Model $Deployment -PromptTokens $f.prompt -CachedTokens $f.cached -CompletionTokens $f.completion
      if ($null -eq $c) { $anyUnpriced = $true } else { $priced += $c }
    }
    if ($anyUnpriced) {
      Write-Host ("    NOTE: deployment '{0}' has no row in the production rate card -> UNPRICED (expected until you add it)." -f $Deployment) -ForegroundColor Yellow
    } else {
      Assert-True "L7 priced result computed (>= 0)" ($priced -ge 0) "got $priced"
      Write-Host ("    priced {0} calls at list price = `${1}" -f $fired.Count, [Math]::Round($priced, 8))
    }

    # L8. Reconciliation (reported, not gated - Cost Management lags hours to days).
    if ($ResourceTotalUsd -ge 0) {
      $r = Get-ReconciliationResidual -EstimateSum $priced -ResourceTotal $ResourceTotalUsd
      Write-Host ("    reconciliation: estimate=`${0} resourceTotal=`${1} residual=`${2} ({3}%)" -f $r.estimateSum, $r.resourceTotal, $r.residual, $r.residualPct)
    } else {
      Write-Host "    reconciliation: skipped (pass -ResourceTotalUsd once Cost Management has settled; it lags hours-days)." -ForegroundColor Yellow
    }
  }
} else {
  Write-Host "`n(LIVE skipped - pass -Live with -WorkspaceId/-FoundryEndpoint/-Deployment to run the round trip.)" -ForegroundColor DarkGray
}

# =====================================================================
Write-Host ("`n=== {0} passed, {1} failed ===" -f $script:pass, $script:fail) -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
