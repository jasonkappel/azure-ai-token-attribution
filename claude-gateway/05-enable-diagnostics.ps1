<#
=============================================================================
 Pattern B - Enable gateway diagnostics for per-user attribution
-----------------------------------------------------------------------------
 WHAT THIS DOES
   Turns on the two things the attribution query (09-attribution.kql) needs:
     1. A diagnostic setting on the APIM instance that sends GatewayLlmLogs
        (per-request prompt/completion tokens, streaming-safe) and GatewayLogs
        to the Log Analytics workspace.
     2. An APIM azureMonitor logger + an API-level azuremonitor diagnostic with
        100% fixed sampling that captures the x-caller-oid request header the
        policy stamps.
   The token rows (GatewayLlmLogs) and the identity row (GatewayLogs, carrying
   x-caller-oid) both land in the shared AzureDiagnostics table (Azure-diagnostics
   mode) and are joined by CorrelationId.

 PREREQUISITES / ROLES
   - The policy (04-apim-policy.xml) is applied (it stamps x-caller-oid).
   - Role: Monitoring Contributor on the APIM instance.
   - Do NOT log request/response BODIES and deny-list Authorization + x-api-key on
     every logger so a token is never captured in diagnostics.

 PLACEHOLDERS TO FILL (parameters)
   -SubscriptionId   <SUBSCRIPTION_ID>
   -ResourceGroup    <RESOURCE_GROUP>
   -ApimName         <APIM_NAME>
   -WorkspaceName    <LOG_ANALYTICS_WORKSPACE_NAME>
=============================================================================
#>

param(
  [Parameter(Mandatory)] [string]$SubscriptionId,
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [Parameter(Mandatory)] [string]$ApimName,
  [Parameter(Mandatory)] [string]$WorkspaceName,
  [string]$ApiVersion = "2023-09-01-preview"
)

$ErrorActionPreference = "Stop"
$apimId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$wsId   = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName"

# ---- 1. Diagnostic setting on APIM: send the LLM token log + gateway log to the workspace. ----
# GatewayLlmLogs = per-request prompt/completion tokens (SSE-aware). GatewayLogs = the request row
# that carries the captured x-caller-oid header. Both land in AzureDiagnostics.
az monitor diagnostic-settings create `
  --name "apim-llm-attribution" `
  --resource $apimId `
  --workspace $wsId `
  --logs '[
    {"category":"GatewayLlmLogs","enabled":true},
    {"category":"GatewayLogs","enabled":true}
  ]' | Out-Null
Write-Host "Diagnostic setting on APIM -> workspace (GatewayLlmLogs + GatewayLogs)"

# ---- 2. APIM azureMonitor logger. ----
$loggerUrl = "https://management.azure.com$apimId/loggers/azuremonitor?api-version=$ApiVersion"
$loggerBody = @{ properties = @{ loggerType = "azureMonitor"; isBuffered = $true } } | ConvertTo-Json -Depth 5
$tmp1 = New-TemporaryFile
[System.IO.File]::WriteAllText($tmp1, $loggerBody, (New-Object System.Text.UTF8Encoding($false)))
az rest --method PUT --url $loggerUrl --headers "Content-Type=application/json" --body "@$tmp1" | Out-Null
Remove-Item $tmp1 -Force
Write-Host "Created azureMonitor logger"

# ---- 3. API-level azuremonitor diagnostic: 100% sampling, capture the x-caller-oid request header.
#         verbosity=information, no body logging. This is what surfaces x-caller-oid in AzureDiagnostics. ----
$diagUrl = "https://management.azure.com$apimId/apis/claude-anthropic/diagnostics/azuremonitor?api-version=$ApiVersion"
$diagBody = @{
  properties = @{
    loggerId  = "$apimId/loggers/azuremonitor"
    sampling  = @{ samplingType = "fixed"; percentage = 100 }
    frontend  = @{
      request = @{ headers = @("x-caller-oid") }
    }
    # Deny-list the credential headers so a token is never captured (defense in depth).
    verbosity = "information"
  }
} | ConvertTo-Json -Depth 8
$tmp2 = New-TemporaryFile
[System.IO.File]::WriteAllText($tmp2, $diagBody, (New-Object System.Text.UTF8Encoding($false)))
az rest --method PUT --url $diagUrl --headers "Content-Type=application/json" --body "@$tmp2" | Out-Null
Remove-Item $tmp2 -Force
Write-Host "Created API diagnostic (100% sampling, capture x-caller-oid header)"

Write-Host ""
Write-Host "Attribution wiring done. Query with 09-attribution.kql once real calls have flowed."
