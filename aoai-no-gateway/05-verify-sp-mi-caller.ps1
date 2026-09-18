<#
=============================================================================
 Pattern A - VERIFICATION: what identity does a SERVICE PRINCIPAL / MANAGED
 IDENTITY caller write to the diagnostic log?  (the open, gated question)
-----------------------------------------------------------------------------
 WHAT THIS DOES
   The no-gateway pattern proves callerObjectId = the HUMAN oid for a USER token.
   It does NOT, on its own, prove the app-only case. This script creates a
   throwaway service principal, calls the model with an app-only (client-
   credentials) token, then inspects what identity landed in the log. Run it in
   YOUR OWN tenant before claiming "per-app native." Clean up afterwards.

   Expected outcomes (one of):
     A) properties_s.callerObjectId = the SP/MI object id  -> per-app native works
     B) a separate appId/azp field appears                 -> capture that instead
     C) identity is blank for app-only tokens              -> per-app needs the
                                                              app-side enrichment join

 PREREQUISITES / ROLES
   - Azure CLI signed in with rights to create an app registration + service
     principal and assign a data-plane role on the resource.
   - If Conditional Access blocks issuing an app-only token for a new app, that
     block is itself the finding: production MI/SP callers may need a CA exception.

 PLACEHOLDERS TO FILL (passed as parameters)
   -Account         Azure OpenAI / Foundry resource name.
   -ResourceGroup   Resource group.
   -Deployment      A chat deployment name.
   -WorkspaceGuid   Log Analytics workspace customerId (GUID).
=============================================================================
#>

param(
  [Parameter(Mandatory)] [string]$Account,        # Azure OpenAI / Foundry resource name
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [Parameter(Mandatory)] [string]$Deployment,     # a chat deployment name
  [Parameter(Mandatory)] [string]$WorkspaceGuid,  # Log Analytics customerId (GUID)
  [string]$ApiVersion = "2025-01-01-preview"
)

$scope = az cognitiveservices account show -n $Account -g $ResourceGroup --query id -o tsv

# 1. Create an app registration + service principal with a short-lived secret,
#    then grant it the Azure OpenAI data-plane role. (Requires the tenant to permit
#    SP token issuance for this app - if Conditional Access blocks it, that itself is
#    the finding: production MI/SP callers may be unreachable without a CA exception.)
$appId = az ad app create --display-name "aoai-attribution-verify" --query appId -o tsv
az ad sp create --id $appId | Out-Null
$end = (Get-Date).AddDays(2).ToString("yyyy-MM-dd")
$secret = az ad app credential reset --id $appId --end-date $end --query password -o tsv
$tenant = az account show --query tenantId -o tsv
az role assignment create --assignee $appId --role "Cognitive Services OpenAI User" --scope $scope | Out-Null
Start-Sleep -Seconds 150   # RBAC propagation

# 2. Get an APP-ONLY token (client credentials) and call the model.
$body = @{ client_id=$appId; client_secret=$secret; scope="https://cognitiveservices.azure.com/.default"; grant_type="client_credentials" }
$tok = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body $body).access_token
$uri = "https://$Account.cognitiveservices.azure.com/openai/deployments/$Deployment/chat/completions?api-version=$ApiVersion"
$call = @{ messages=@(@{role="user";content="SP_VERIFY reply ok"}); max_tokens=8 } | ConvertTo-Json -Depth 5
$r = Invoke-WebRequest -Uri $uri -Method Post -Headers @{ "Authorization"="Bearer $tok"; "Content-Type"="application/json" } -Body $call
$apimId = $r.Headers['apim-request-id']
Write-Host "SP call apim-request-id = $apimId  (SP appId = $appId)"

# 3. Wait for ingestion, then inspect what identity landed for the SP call.
Start-Sleep -Seconds 600
$kql = @"
AzureDiagnostics
| where TimeGenerated > ago(30m)
| where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES'
| where Category == 'RequestResponse' and event_s == 'ShoeboxCallResult'
| where CorrelationId == '$apimId'
| extend p = parse_json(properties_s)
| project CorrelationId,
          callerObjectId = tostring(p.callerObjectId),
          objectId       = tostring(p.objectId),
          appId_flat     = column_ifexists('identity_claim_appid_g',''),
          objId_flat     = column_ifexists('identity_claim_http_schemas_microsoft_com_identity_claims_objectidentifier_g',''),
          promptTokens   = tolong(p.promptTokens),
          completionTokens = tolong(p.completionTokens)
"@
$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $kql -NoNewline
az monitor log-analytics query --workspace $WorkspaceGuid --analytics-query "@$tmp" -o json

Write-Host ""
Write-Host "INTERPRET: is callerObjectId the SP object id (A), a separate appId field (B), or blank (C)?"
Write-Host "CLEANUP: az ad app delete --id $appId ; and remove the role assignment."
