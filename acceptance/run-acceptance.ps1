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
  [double]$ResourceTotalUsd = -1,    # supply the resource-day Marketplace total to compute a residual; <0 = skip
  [double]$ReconcileTolerance = -1,  # with -ResourceTotalUsd, GATE |residual| <= this (USD); <0 = report only
  [string]$TokenAudience = "https://cognitiveservices.azure.com"  # classic AOAI data-plane audience (proven).
)                                    # Current Foundry docs use https://ai.azure.com; both are accepted in transition.

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

# Run a KQL query from a BOM-less temp file and return the parsed rows (empty array on failure).
function Run-Kql([string]$query, [string]$wsId) {
  $tmp = New-TemporaryFile
  [System.IO.File]::WriteAllText($tmp, $query, (New-Object System.Text.UTF8Encoding($false)))
  try {
    $j = az monitor log-analytics query --workspace $wsId --analytics-query "@$tmp" -o json 2>$null
    if ([string]::IsNullOrWhiteSpace($j)) { return @() }
    return @($j | ConvertFrom-Json)
  } catch { return @() } finally { Remove-Item $tmp -Force }
}

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

Write-Host "`n-- OFFLINE: output is billed in full; thinking can't enter the dollar --"
# Pin the OUTPUT contribution by differencing two calls that differ ONLY in output tokens.
# out=200 -> 0.0175 ; out=0 -> 0.0135. Delta must be EXACTLY 200 * out_rate(20) / 1e6 = 0.004.
# A "subtract thinking from output" bug would shrink this delta; a strict-equality assert catches it.
$cOut200 = Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 200 -CacheWrite5m 1000
$cOut0   = Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 0   -CacheWrite5m 1000
Assert-Near "output billed in full (200 tokens contribute exactly 200*rate)" ($cOut200 - $cOut0) 0.004
# Structural guarantee: Get-ClaudeCost exposes NO thinking parameter, so thinking can never be priced.
# If someone later adds one, this fails and forces a decision instead of a silent double-count.
$hasThinkingParam = (Get-Command Get-ClaudeCost).Parameters.Keys -contains 'ThinkingTokens'
Assert-True "cost model has NO thinking parameter (thinking is unpriceable by construction)" (-not $hasThinkingParam) "a ThinkingTokens param exists"

Write-Host "`n-- OFFLINE: cache-write double-count guards --"
# scalar total AND 5m both present -> the fallback must NOT add the scalar on top of 5m (5m wins).
Assert-Near "scalar+5m both set: no double-count (5m only)" (Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 200 -CacheWrite5m 1000 -CacheCreationTotal 1000) 0.0175
# 5m AND 1h both present -> both priced at their own tiers (12.5 + 20 per token here).
Assert-Near "5m+1h both present: each tier priced" (Get-ClaudeCost -Rates $rc -Model 'test-claude' -InputTokens 100 -OutputTokens 200 -CacheWrite5m 400 -CacheWrite1h 600) (( 100*10 + 200*20 + 400*12.5 + 600*20 ) / 1000000.0)

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
# Rows with an EMPTY idempotency key cannot be deduped blindly - keep them (a missing key is a
# capture defect to surface, not a licence to merge unrelated calls).
$noKey = @([pscustomobject]@{ apimRequestId = ''; promptTokens = 1 }, [pscustomobject]@{ apimRequestId = ''; promptTokens = 1 })
Assert-Eq "dedup keeps rows with EMPTY idempotency key" (Merge-Dedup -Rows $noKey -IdField 'apimRequestId').Count 2
$cov = Get-Coverage -Expected 8 -Captured 6
Assert-Near "coverage 6/8 = 75%" $cov.pct 75
$recon = Get-ReconciliationResidual -EstimateSum 90 -ResourceTotal 100
Assert-Near "reconciliation residual = 10" $recon.residual 10
Assert-Near "reconciliation residual = 10%" $recon.residualPct 10

# =====================================================================
#  LIVE: identity -> usage -> ingestion -> priced result (Pattern A)
#  NOTE: the platform-log fields this exercises - callerObjectId, the properties_s token
#  counts, and event_s == 'ShoeboxCallResult' - are PILOT-OBSERVED, not documented/contracted
#  by Microsoft. If Microsoft renames them or moves to a dedicated table, these asserts fail
#  (loudly, by design). Pin the probe to a NON-STREAMING, NON-REASONING, no-tools deployment:
#  on reasoning models the logged completion count can legitimately differ from the response
#  usage (reasoning tokens), which would falsely fail the token-equality assert.
# =====================================================================
$liveRan = $false
if ($Live) {
  Write-Host "`n-- LIVE: Pattern A round trip --" -ForegroundColor Cyan
  if (-not $WorkspaceId -or -not $FoundryEndpoint -or -not $Deployment) {
    Bad "live prerequisites" "-Live requires -WorkspaceId, -FoundryEndpoint and -Deployment"
  } else {
    $liveRan = $true
    Add-Type -AssemblyName System.Net.Http

    # L1. Identity: who are we, per Entra? (az id == token oid is documented; oid == callerObjectId is pilot-observed.)
    $signedInOid = (az ad signed-in-user show --query id -o tsv 2>$null)
    Assert-True "L1 identity: signed-in oid resolved" (-not [string]::IsNullOrWhiteSpace($signedInOid)) "run 'az login'"

    # L2. RBAC preflight: querying via --workspace needs a WORKSPACE-scoped read right (Log Analytics
    #     Reader on the workspace), not just Reader on the AOAI resource.
    $probe = az monitor log-analytics query --workspace $WorkspaceId --analytics-query "print ping=1" -o json 2>$null
    Assert-True "L2 RBAC: workspace is queryable" ($LASTEXITCODE -eq 0 -and $probe) "grant 'Log Analytics Reader' on the workspace"

    # L3. Fire CallCount known calls AS THE USER (user token), capture usage + apim-request-id.
    $aoaiTok = az account get-access-token --resource $TokenAudience --query accessToken -o tsv 2>$null
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

    # L4. Wait for ingestion, then pull the ATTRIBUTED (filtered) rows for our CorrelationIds.
    $ids = ($fired | ForEach-Object { "'" + $_.apimId + "'" }) -join ","
    $kqlFiltered = @"
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
      $rows = @(Run-Kql $kqlFiltered $WorkspaceId)
      if ($rows.Count -ge $fired.Count) { break }
      Start-Sleep -Seconds 20; $waited += 20
      Write-Host ("    ...waiting for ingestion ({0}s, {1}/{2} rows)" -f $waited, $rows.Count, $fired.Count)
    }
    # Fail LOUD (not silently zero) if the pilot-observed field yielded nothing.
    Assert-True "L4 ingestion: ShoeboxCallResult rows arrived" ($rows.Count -gt 0) "0 rows after ${MaxWaitSeconds}s - ingestion lag, or the pilot-observed callerObjectId/event_s changed"

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
    Assert-True "L5 tokens: platform log == model usage object" $tokensOk "logged tokens differ from the API usage (reasoning/streaming?)"

    # L5b. Prove the dedup FILTER is load-bearing: the RequestResponse category emits 2 rows/call, so
    #      the UNFILTERED count for our ids must exceed the attributed count (else isnotempty(oid) did nothing).
    $kqlUnfiltered = @"
AzureDiagnostics
| where TimeGenerated > ago(${LookbackMinutes}m)
| where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES'
| where Category == 'RequestResponse' and event_s == 'ShoeboxCallResult'
| where CorrelationId in ($ids)
| count
"@
    $unfiltered = @(Run-Kql $kqlUnfiltered $WorkspaceId)
    $unfilteredCount = if ($unfiltered.Count -gt 0) { [int]$unfiltered[0].Count } else { 0 }
    Assert-True "L5b filter is load-bearing: unfiltered rows > attributed rows" ($unfilteredCount -gt $deduped.Count) "unfiltered=$unfilteredCount attributed=$($deduped.Count) - the twin-row filter removed nothing"

    # L5c. Independent meter cross-check: join AzureOpenAIRequestUsage (a SEPARATE log category) and
    #      assert cached is a subset of prompt on the usage log itself - not just an echo of the response.
    $kqlUsage = @"
AzureDiagnostics
| where TimeGenerated > ago(${LookbackMinutes}m)
| where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES'
| where Category == 'AzureOpenAIRequestUsage'
| extend u = parse_json(properties_s)
| where CorrelationId in ($ids)
| project CorrelationId, uPrompt = tolong(u.promptTokens[0]), uCached = tolong(u.cachedTokens[0])
"@
    $usageRows = @(Run-Kql $kqlUsage $WorkspaceId)
    $cachedSubsetOk = $true
    foreach ($ur in $usageRows) { if ([long]$ur.uCached -gt [long]$ur.uPrompt) { $cachedSubsetOk = $false } }
    Assert-True "L5c independent usage log joins on CorrelationId" ($usageRows.Count -gt 0) "AzureOpenAIRequestUsage returned no rows for our ids"
    Assert-True "L5c cached is a subset of prompt (usage log)" $cachedSubsetOk "cachedTokens > promptTokens in AzureOpenAIRequestUsage"

    # L5d. Negative discrimination: a KNOWN-ABSENT CorrelationId must return ZERO rows. This kills the
    #      'coverage is 100% by construction' tautology - it proves the query actually discriminates.
    $fakeId = [guid]::NewGuid().ToString()
    $kqlNeg = @"
AzureDiagnostics
| where TimeGenerated > ago(${LookbackMinutes}m)
| where Category == 'RequestResponse' and event_s == 'ShoeboxCallResult'
| where CorrelationId == '$fakeId'
| count
"@
    $neg = @(Run-Kql $kqlNeg $WorkspaceId)
    $negCount = if ($neg.Count -gt 0) { [int]$neg[0].Count } else { 0 }
    Assert-Eq "L5d negative control: an absent CorrelationId returns 0 rows" $negCount 0

    # L6. Coverage (now meaningful because L5d proved the query discriminates).
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

    # L8. Reconciliation. Report by default; GATE only when a settled total AND a tolerance are supplied.
    #     WARNING: comparing a few probe calls to a resource-DAY total is meaningless unless that day
    #     contains ONLY these probes. Scope the resource total to the same calls/window before gating.
    if ($ResourceTotalUsd -ge 0) {
      $r = Get-ReconciliationResidual -EstimateSum $priced -ResourceTotal $ResourceTotalUsd
      Write-Host ("    reconciliation: estimate=`${0} resourceTotal=`${1} residual=`${2} ({3}%)" -f $r.estimateSum, $r.resourceTotal, $r.residual, $r.residualPct)
      Write-Host "    (ensure resourceTotal is scoped to THESE calls, not an unrelated resource-day total.)" -ForegroundColor Yellow
      if ($ReconcileTolerance -ge 0) {
        Assert-True "L8 reconciliation within tolerance" ([Math]::Abs($r.residual) -le $ReconcileTolerance) "residual $($r.residual) > tolerance $ReconcileTolerance"
      } else {
        Write-Host "    reconciliation: REPORTED not gated (pass -ReconcileTolerance to gate a settled, scope-aligned period)." -ForegroundColor Yellow
      }
    } else {
      Write-Host "    reconciliation: PENDING (pass -ResourceTotalUsd once Cost Management has settled; it lags hours-days)." -ForegroundColor Yellow
    }
  }
} else {
  Write-Host "`n(LIVE skipped - pass -Live with -WorkspaceId/-FoundryEndpoint/-Deployment to run the round trip.)" -ForegroundColor DarkGray
}

# =====================================================================
#  Scoped result banner - so a green run is never overstated as more than it tested.
# =====================================================================
$rev = (git -C $PSScriptRoot rev-parse --short HEAD 2>$null); if (-not $rev) { $rev = "unknown" }
$stamp = (Get-Date).ToUniversalTime().ToString("o")
Write-Host "`n=== RESULT (toolkit rev $rev, $stamp) ===" -ForegroundColor Cyan
if ($script:fail -eq 0) { Write-Host "  OFFLINE LOGIC: PASS" } else { Write-Host "  OFFLINE LOGIC: FAIL" }
if ($liveRan) {
  if ($script:fail -eq 0) { Write-Host "  PATTERN A LIVE: PASS" } else { Write-Host "  PATTERN A LIVE: FAIL" }
  $reconStatus = if ($ResourceTotalUsd -ge 0 -and $ReconcileTolerance -ge 0) { "RECONCILIATION: GATED" } elseif ($ResourceTotalUsd -ge 0) { "RECONCILIATION: REPORTED (not gated)" } else { "RECONCILIATION: PENDING" }
  Write-Host ("  {0}" -f $reconStatus)
} else {
  Write-Host "  PATTERN A LIVE: NOT RUN (offline only - this proves LOGIC, not your deployment)" -ForegroundColor Yellow
  Write-Host "  RECONCILIATION: NOT RUN"
}
Write-Host "  PATTERN B (Claude gateway): NOT TESTED here (needs a wired gateway; see docs/03)" -ForegroundColor Yellow
Write-Host "  SECURITY CONTROLS (least-privilege, app-only-not-attributed, unauthorized-denied): NOT TESTED" -ForegroundColor Yellow
Write-Host ("`n=== {0} passed, {1} failed ===" -f $script:pass, $script:fail) -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
