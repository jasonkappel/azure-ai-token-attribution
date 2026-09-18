<#
=============================================================================
 Portal spend-record WRITER - reference emitter for AiSpendEnrichment_CL
-----------------------------------------------------------------------------
 WHAT THIS DOES
   Sends spend records to the AiSpendEnrichment_CL custom table (created by
   portal/enrichment-table-dcr.bicep) via the Logs Ingestion API, so the portal's
   enriched department -> app -> user view has data to read. This is the WRITER half
   of the enrichment path; the bicep is the CREATE half and the portal is the READ
   half. Without a writer like this, that table stays empty and the portal falls back
   to per-principal attribution from the native logs.

   This is a REFERENCE implementation. In production your application emits one record
   per call from its OWN context; here we take a JSON array of records (or emit a
   single demo record) so you can prove the create -> write -> read loop end to end.

 THE HONEST RULES (enforced by convention, not by this script)
   - department / app / cost-center come from the app's OWN governed context or a
     governed map keyed by oid/AppId - NEVER from anything the caller can type.
   - inputTokens is ALREADY-UNCACHED input for both families (Claude input_tokens;
     Azure OpenAI prompt - cached). outputTokens includes thinking. thinkingTokens is
     a subset of output, for transparency only. See docs/01-how-it-works.md.
   - A lost write must reduce COVERAGE visibly - never silently lower a charge. Buffer
     and retry on the app side; do not fail the inference path on a telemetry error.

 PREREQUISITES / ROLES
   - The table + DCE + DCR exist (deploy portal/enrichment-table-dcr.bicep first).
   - The sending identity holds Monitoring Metrics Publisher on the DCR (the bicep
     assigns it to the senderPrincipalId you pass).
   - Azure CLI signed in. NOTE: if tenant Conditional Access blocks service-principal
     (client-credentials) tokens, ingest with the signed-in USER's token instead -
     grant that user Monitoring Metrics Publisher on the DCR and run as yourself.

 PLACEHOLDERS TO FILL (parameters)
   -DceEndpoint      The DCE logs-ingestion endpoint (bicep output dceLogsIngestionEndpoint),
                     e.g. https://dce-aispend-xxxx.<region>.ingest.monitor.azure.com
   -DcrImmutableId   The DCR immutableId (bicep output dcrImmutableId), e.g. dcr-xxxx…
   -RecordsPath      (optional) Path to a JSON array of records to send. If omitted, one
                     demo record is emitted so you can confirm the loop works.
=============================================================================
#>
param(
  [Parameter(Mandatory)] [string]$DceEndpoint,
  [Parameter(Mandatory)] [string]$DcrImmutableId,
  [string]$StreamName = "Custom-AiSpendEnrichment_CL",
  [string]$RecordsPath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http

# 1. Acquire a token for the Logs Ingestion API (monitor.azure.com).
#    Uses the signed-in user by default (works even where CA blocks SP tokens).
$token = az account get-access-token --resource "https://monitor.azure.com" --query accessToken -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($token)) { throw "Failed to get a monitor.azure.com token. Run 'az login'." }

# 2. Build the payload. Either load your records, or emit ONE demo record so the loop is provable.
if ($RecordsPath -and (Test-Path $RecordsPath)) {
  $records = Get-Content $RecordsPath -Raw | ConvertFrom-Json
  if ($records -isnot [System.Array]) { $records = @($records) }
} else {
  Write-Host "No -RecordsPath given: emitting ONE demo record (replace with your app's real emit)."
  $records = @(
    [ordered]@{
      TimeGenerated    = ([DateTime]::UtcNow).ToString("o")
      oid              = "00000000-0000-0000-0000-000000000000"  # the caller's Entra oid in production
      userName         = "Demo User"
      department       = "Demo Department"     # from a governed map, not caller input
      app              = "Demo App"
      pipeline         = "aoai"                # "aoai" | "gateway"
      model            = "gpt-4.1-mini"
      inputTokens      = 100                   # already-uncached
      outputTokens     = 40
      cacheWriteTokens = 0
      cacheReadTokens  = 0
      thinkingTokens   = 0
      estCost          = 0.0                   # optional; the portal re-prices from the rate card
      correlationId    = [guid]::NewGuid().ToString()
    }
  )
}

# 3. POST to the DCR stream. A 204 = accepted; ingestion latency is ~1-5 min (first-time longer).
$payload = $records | ConvertTo-Json -Depth 6
if ($records.Count -eq 1) { $payload = "[$payload]" }   # the API wants an array
$uri = "$DceEndpoint/dataCollectionRules/$DcrImmutableId/streams/$StreamName`?api-version=2023-01-01"

$client = [System.Net.Http.HttpClient]::new()
$req = [System.Net.Http.HttpRequestMessage]::new("Post", $uri)
$req.Headers.Add("Authorization", "Bearer $token")
$req.Content = [System.Net.Http.StringContent]::new($payload, [System.Text.Encoding]::UTF8, "application/json")
$resp = $client.SendAsync($req).GetAwaiter().GetResult()
$status = [int]$resp.StatusCode
$client.Dispose()

if ($status -eq 204) {
  Write-Host "Sent $($records.Count) record(s). Status 204 (accepted). Allow ~1-5 min, then run portal/query-helper.ps1."
} else {
  $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  throw "Ingestion failed: HTTP $status - $body"
}
