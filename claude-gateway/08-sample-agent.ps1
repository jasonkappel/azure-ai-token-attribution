<#
=============================================================================
 Pattern B - Sample agent: exercise the gateway end to end and record usage
-----------------------------------------------------------------------------
 WHAT THIS DOES
   Mints ONE per-user Entra token, then loops a few prompts across your Claude
   deployments through the APIM gateway, recording per call: caller oid, model,
   the FULL Anthropic usage object - input (already uncached), output,
   cache_creation (with the ephemeral_5m / ephemeral_1h write tiers),
   cache_read, and output_tokens_details.thinking_tokens (a SUBSET of output) -
   plus the gateway quota headers (x-tokens-consumed, x-remaining-tokens) and the
   apim-request-id. It stands in for a real client so you can prove attribution
   and the per-user quota decrement before wiring up Claude Code itself.

   STREAMING CAVEAT (read before you trust cache in production): this sample makes
   NON-STREAMING calls, so the single JSON response carries the whole usage object.
   A streamed Claude response splits usage across frames - message_start.usage has
   input + cache_creation + cache_read, and the terminal message_delta.usage has
   output only. If you capture "the last usage object" you ZERO cache and input; you
   must MERGE message_start UNION message_delta. Do NOT reconstruct this by buffering
   the response body in an APIM outbound policy (buffering defeats SSE and the body is
   multi-frame, not one JObject). For streaming production capture usage app-side, or
   use the SSE-aware llm-emit-token-metric policy for gateway metering (prompt+
   completion only, no cache).

   Why this exists: Claude Code cannot do interactive Entra OAuth to a custom
   gateway, and on a Conditional-Access-managed workstation silent token
   acquisition may be blocked. This script isolates the gateway behavior from the
   CLI so you can validate each half independently.

 IMPORTANT - POOLED HttpClient
   This uses ONE reused System.Net.Http.HttpClient for every call. Do NOT use
   Invoke-WebRequest in a loop: it opens a fresh socket per request and a burst of
   calls exhausts ephemeral ports (TIME_WAIT), so the batch fails partway with
   connection errors. A single pooled HttpClient reuses connections and is the fix.

 PREREQUISITES
   - `az login` as a user holding the Claude.User app role.
   - The gateway is provisioned, wired, and the policy is applied (01-05).

 PLACEHOLDERS TO FILL (parameters)
   -ApimName        <APIM_NAME>
   -GatewayAppId    <GATEWAY_APP_ID>
   -TenantId        <TENANT_ID>
   -Deployments     one or more Foundry Claude deployment names to exercise
=============================================================================
#>

param(
  [Parameter(Mandatory)] [string]$ApimName,
  [Parameter(Mandatory)] [string]$GatewayAppId,
  [Parameter(Mandatory)] [string]$TenantId,
  [string[]]$Deployments = @("<CLAUDE_HAIKU_DEPLOYMENT>", "<CLAUDE_SONNET_DEPLOYMENT>"),
  [string[]]$Prompts = @("Reply with just: ok", "Name one primary color.", "What is 2+2?")
)

$ErrorActionPreference = "Stop"

# ---- 1. Mint ONE per-user token for the gateway audience (api://<GATEWAY_APP_ID>/.default). ----
$token = az account get-access-token `
  --scope "api://$GatewayAppId/.default" --tenant $TenantId `
  --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($token)) { throw "Failed to mint a gateway token. Run 'az login' and confirm Claude.User." }

# Decode the oid from the JWT payload (for local logging only; the gateway is the real source of record).
function Get-JwtClaim([string]$jwt, [string]$claim) {
  $p = $jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
  switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
  $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
  return $json.$claim
}
$oid = Get-JwtClaim $token "oid"
Write-Host "Minted token for oid=$oid"

# ---- 2. ONE pooled HttpClient for the whole run (see the POOLED note above). ----
$handler = [System.Net.Http.HttpClientHandler]::new()
$http = [System.Net.Http.HttpClient]::new($handler)
$http.BaseAddress = [Uri]"https://$ApimName.azure-api.net/"
$http.DefaultRequestHeaders.Authorization =
  [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $token)
$http.DefaultRequestHeaders.Add("anthropic-version", "2023-06-01")

$results = @()
foreach ($model in $Deployments) {
  foreach ($prompt in $Prompts) {
    $payload = @{
      model      = $model
      max_tokens = 64
      messages   = @(@{ role = "user"; content = $prompt })
    } | ConvertTo-Json -Depth 6

    $content = [System.Net.Http.StringContent]::new($payload, [Text.Encoding]::UTF8, "application/json")
    $resp = $http.PostAsync("anthropic/v1/messages", $content).GetAwaiter().GetResult()
    $bodyText = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()

    # Gateway quota headers stamped by llm-token-limit.
    $consumed  = $null; $remaining = $null; $apimId = $null
    [void]($resp.Headers.TryGetValues("x-tokens-consumed", [ref]$consumed))
    [void]($resp.Headers.TryGetValues("x-remaining-tokens", [ref]$remaining))
    [void]($resp.Headers.TryGetValues("apim-request-id", [ref]$apimId))

    $usage = $null
    if ($resp.IsSuccessStatusCode) { $usage = ($bodyText | ConvertFrom-Json).usage }

    # Pull the write tiers + thinking defensively (absent on some models / versions).
    $cw = $usage.cache_creation
    $cw5m = if ($cw) { [int]$cw.ephemeral_5m_input_tokens } else { 0 }
    $cw1h = if ($cw) { [int]$cw.ephemeral_1h_input_tokens } else { 0 }
    $think = if ($usage.output_tokens_details) { [int]$usage.output_tokens_details.thinking_tokens } else { 0 }
    # Integrity gate: thinking is a SUBSET of output. If it ever exceeds output the shape changed
    # (additive thinking) and the cost math would be wrong - surface it, do not silently trust it.
    if ($usage -and $think -gt [int]$usage.output_tokens) {
      Write-Warning ("thinking ({0}) > output ({1}) for {2} - meter shape changed; verify pricing." -f $think, $usage.output_tokens, $model)
    }

    $results += [pscustomobject]@{
      oid            = $oid
      model          = $model
      status         = [int]$resp.StatusCode
      input          = $usage.input_tokens          # already uncached (exclusive of cache meters)
      output         = $usage.output_tokens         # includes thinking tokens
      cache_creation = $usage.cache_creation_input_tokens   # total write (= 5m + 1h)
      cache_write_5m = $cw5m                         # ~1.25x input
      cache_write_1h = $cw1h                         # ~2x input (coding agents live here)
      cache_read     = $usage.cache_read_input_tokens       # ~0.1x input
      thinking       = $think                        # SUBSET of output - display only, never add to cost
      rawUsage       = if ($usage) { ($usage | ConvertTo-Json -Compress -Depth 6) } else { $null }  # verbatim, so a new meter never forces a re-capture
      tokensConsumed = ($consumed  -join ",")
      tokensRemaining= ($remaining -join ",")
      apimRequestId  = ($apimId    -join ",")
    }
    Write-Host ("  {0,-28} status={1} in={2} out={3} remaining={4}" -f $model, [int]$resp.StatusCode, $usage.input_tokens, $usage.output_tokens, ($remaining -join ","))
  }
}

$http.Dispose(); $handler.Dispose()

Write-Host ""
Write-Host "==== Per-call record (this is what the gateway log will attribute to oid=$oid) ===="
$results | Format-Table -AutoSize
# Note: per-user cache tokens shown here come from the response body for THIS test client only.
# In production with streaming Claude Code, cache is NOT captured at the gateway - reconcile the
# cache total at the resource level (see 09-attribution.kql Q3). Per-user attribution in production
# is prompt+completion from the native ApiManagementGatewayLlmLog joined to x-caller-oid.
#
# This script PRINTS its capture; it is not a portal source. If you build an ingestion adapter to
# feed these full-meter rows into the portal, do NOT union them with the gateway log - both carry
# prompt+completion, so a union double-counts. Pick ONE source of record per call; if you merge,
# replace by apim-request-id (never union) and tag each row with usage_source = "app_reported".
