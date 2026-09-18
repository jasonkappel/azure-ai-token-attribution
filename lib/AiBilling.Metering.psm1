<#
=============================================================================
 AiBilling.Metering - canonical token-meter cost model (single source of truth)
-----------------------------------------------------------------------------
 This module is the ONE implementation of the two token-cost algebras, the
 integrity gates, dedup, coverage, and reconciliation. Both the portal
 (portal/query-helper.ps1) and the acceptance test (acceptance/run-acceptance.ps1)
 import it, so the test exercises the SAME math the portal ships - never a copy
 that can silently drift.

 Design rules (see docs/01-how-it-works.md "Token meters: two algebras"):
   - Azure OpenAI: prompt_tokens INCLUDES cached -> billable input = prompt - cached.
     No cache-write on pre-GPT-5.6; GPT-5.6+ bills cache_write_tokens separately.
     reasoning_tokens are a SUBSET of completion (already billed as output).
   - Claude: input_tokens is EXCLUSIVE of cache meters -> total input = input +
     cache_creation + cache_read (ADD, never subtract). cache_creation splits into
     ephemeral_5m (~1.25x) and ephemeral_1h (~2x); the two SUM to
     cache_creation_input_tokens. cache_read ~0.1x. thinking_tokens are a SUBSET
     of output - shown for transparency, NEVER added to or subtracted from cost.
   - Unknown price => $null (UNPRICED), never $0.

 PowerShell 5.1 compatible: no null-coalescing (??), no ternary (? :).
=============================================================================
#>

Set-StrictMode -Version Latest

function Import-RateCard {
    <# Load an effective-dated rate card CSV into a per-model rate lookup (USD per 1e6 tokens). #>
    param([Parameter(Mandatory)][string]$Path)
    $rates = @{}
    if (-not (Test-Path $Path)) { return $rates }
    $col = {
        param($row, $name)
        if ($row.PSObject.Properties[$name] -and $row.$name) { return [double]$row.$name } else { return 0.0 }
    }
    Import-Csv $Path | Where-Object { $_.model -and $_.model -notmatch '^\s*#' } | ForEach-Object {
        $rates[$_.model] = @{
            input     = (& $col $_ 'input_per_1m')
            cached    = (& $col $_ 'cached_input_per_1m')       # AOAI cached-read discount
            output    = (& $col $_ 'output_per_1m')
            cacheW5m  = (& $col $_ 'cache_write_5m_per_1m')      # Claude 5m write (~1.25x)
            cacheW1h  = (& $col $_ 'cache_write_1h_per_1m')      # Claude 1h write (~2x)
            cacheRead = (& $col $_ 'cache_read_per_1m')          # Claude read (~0.1x)
        }
    }
    return $rates
}

function Get-AoaiCost {
    <# Azure OpenAI (inclusive algebra). Returns $null when the model has no rate row. #>
    param(
        [Parameter(Mandatory)][hashtable]$Rates,
        [Parameter(Mandatory)][string]$Model,
        [long]$PromptTokens = 0, [long]$CachedTokens = 0, [long]$CompletionTokens = 0
    )
    if (-not $Rates.ContainsKey($Model)) { return $null }
    $rc = $Rates[$Model]
    $billable = [Math]::Max($PromptTokens - $CachedTokens, 0)     # cached is a SUBSET of prompt
    return ($billable * $rc.input + $CachedTokens * $rc.cached + $CompletionTokens * $rc.output) / 1000000.0
}

function Get-ClaudeCost {
    <#
      Claude (exclusive/additive algebra). input is already uncached, so ADD the cache meters.
      thinking is NOT a parameter here on purpose: it is a subset of output and never priced.
      Scalar fallback: if the 5m/1h split is absent but the scalar cache_creation total is present,
      price it at the 5m rate rather than silently billing a captured write at $0.
      Returns $null when the model has no rate row.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Rates,
        [Parameter(Mandatory)][string]$Model,
        [long]$InputTokens = 0, [long]$OutputTokens = 0,
        [long]$CacheWrite5m = 0, [long]$CacheWrite1h = 0, [long]$CacheRead = 0,
        [long]$CacheCreationTotal = 0
    )
    if (-not $Rates.ContainsKey($Model)) { return $null }
    $rc = $Rates[$Model]
    $w5 = $CacheWrite5m; $w1 = $CacheWrite1h
    if ($w5 -eq 0 -and $w1 -eq 0 -and $CacheCreationTotal -gt 0) { $w5 = $CacheCreationTotal }  # never free a captured write
    return ( $InputTokens * $rc.input + $OutputTokens * $rc.output `
           + $w5 * $rc.cacheW5m + $w1 * $rc.cacheW1h + $CacheRead * $rc.cacheRead ) / 1000000.0
}

function Test-UsageIntegrity {
    <#
      Per-row integrity gates. Returns an array of violation strings (empty array = clean).
      A violation means the meter SHAPE changed - the caller must surface it, not silently bill.
      Pass -Family 'claude' or 'aoai'. Unset meters default to 0.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('claude','aoai')][string]$Family,
        [long]$OutputTokens = 0, [long]$ThinkingTokens = 0,
        [long]$PromptTokens = 0, [long]$CachedTokens = 0,
        [long]$CacheCreationTotal = 0, [long]$CacheWrite5m = 0, [long]$CacheWrite1h = 0
    )
    $v = New-Object System.Collections.Generic.List[string]
    # thinking / reasoning is always a subset of output
    if ($ThinkingTokens -gt $OutputTokens) {
        $v.Add("thinking ($ThinkingTokens) > output ($OutputTokens): additive-shape change, cost math unsafe")
    }
    if ($Family -eq 'aoai') {
        if ($CachedTokens -gt $PromptTokens) {
            $v.Add("cached ($CachedTokens) > prompt ($PromptTokens): cached is not a subset here")
        }
    }
    if ($Family -eq 'claude') {
        # ephemeral tiers must sum to the scalar cache_creation total (when both are present)
        if ($CacheCreationTotal -gt 0 -and ($CacheWrite5m -gt 0 -or $CacheWrite1h -gt 0)) {
            if (($CacheWrite5m + $CacheWrite1h) -ne $CacheCreationTotal) {
                $v.Add("ephemeral 5m+1h ($($CacheWrite5m + $CacheWrite1h)) != cache_creation ($CacheCreationTotal): would double- or under-count writes")
            }
        }
    }
    return $v.ToArray()
}

function Merge-Dedup {
    <#
      Collapse rows that share the same idempotency key to ONE row (keep first seen).
      A retried or double-logged call must count once. Returns the deduped array.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows, [Parameter(Mandatory)][string]$IdField)
    $seen = @{}; $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Rows) {
        $id = [string]$r.$IdField
        if ([string]::IsNullOrEmpty($id)) { $out.Add($r); continue }   # no key => cannot dedup, keep
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $out.Add($r) }
    }
    return $out.ToArray()
}

function Get-Coverage {
    <# Fraction of expected calls actually captured. A missing row must lower coverage VISIBLY. #>
    param([Parameter(Mandatory)][int]$Expected, [Parameter(Mandatory)][int]$Captured)
    if ($Expected -le 0) { return [pscustomobject]@{ expected = $Expected; captured = $Captured; pct = $null } }
    return [pscustomobject]@{
        expected = $Expected; captured = $Captured
        pct = [Math]::Round(100.0 * $Captured / $Expected, 2)
    }
}

function Get-ReconciliationResidual {
    <#
      Named residual between the summed per-user estimate and the resource-level authoritative
      total (Marketplace / Cost Management). Report it; NEVER smear it across individuals.
    #>
    param([Parameter(Mandatory)][double]$EstimateSum, [Parameter(Mandatory)][double]$ResourceTotal)
    $residual = $ResourceTotal - $EstimateSum
    $pct = $null
    if ($ResourceTotal -ne 0) { $pct = [Math]::Round(100.0 * $residual / $ResourceTotal, 2) }
    return [pscustomobject]@{ estimateSum = $EstimateSum; resourceTotal = $ResourceTotal; residual = $residual; residualPct = $pct }
}

Export-ModuleMember -Function Import-RateCard, Get-AoaiCost, Get-ClaudeCost, Test-UsageIntegrity, Merge-Dedup, Get-Coverage, Get-ReconciliationResidual
