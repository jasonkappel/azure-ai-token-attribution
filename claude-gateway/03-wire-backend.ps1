<#
=============================================================================
 Pattern B - Wire the Foundry Claude backend into APIM and apply the policy
-----------------------------------------------------------------------------
 WHAT THIS DOES
   1. Creates the APIM API (id=claude-anthropic, path=anthropic) that fronts the
      Foundry Claude Anthropic Messages endpoint, with subscriptionRequired=false
      (the Entra user token is the auth; APIM would otherwise also demand a sub key).
   2. Adds the POST /v1/messages operation.
   3. Grants the APIM managed identity the Foundry data-plane role on the Foundry
      resource so the gateway can call the backend as itself.
   4. Applies 04-apim-policy.xml to the API via ARM REST.

 GOTCHA (learned the hard way): az rest fails if the request body is written with a
 UTF-8 BOM. This script writes the policy JSON body with WriteAllText + a BOM-less
 UTF8Encoding, which is why it does not just pipe a here-string.

 PREREQUISITES / ROLES
   - 01-apim-basicv2.arm.json deployed (APIM v2 with a system-assigned identity).
   - 02-gateway-app-registration.ps1 run (you have <GATEWAY_APP_ID>).
   - Foundry Claude deployed; note the resource name and that billing is Azure
     Marketplace token-metered pay-as-you-go.
   - Rights: API Management Service Contributor on APIM, and Owner/User Access
     Administrator on the Foundry resource (to assign the role in step 3).

 PLACEHOLDERS TO FILL (parameters)
   -SubscriptionId        <SUBSCRIPTION_ID>
   -ResourceGroup         <RESOURCE_GROUP>
   -ApimName              <APIM_NAME>
   -FoundryResourceName   <FOUNDRY_RESOURCE_NAME>
   -ApimPrincipalId       <APIM_MI_PRINCIPAL_ID>  (from the ARM deployment output)
   -PolicyFile            path to 04-apim-policy.xml (already has tenant + app id filled in)
=============================================================================
#>

param(
  [Parameter(Mandatory)] [string]$SubscriptionId,
  [Parameter(Mandatory)] [string]$ResourceGroup,
  [Parameter(Mandatory)] [string]$ApimName,
  [Parameter(Mandatory)] [string]$FoundryResourceName,
  [Parameter(Mandatory)] [string]$ApimPrincipalId,
  [string]$PolicyFile = "$PSScriptRoot/04-apim-policy.xml",
  [string]$ApiVersion = "2023-09-01-preview"
)

$ErrorActionPreference = "Stop"
$base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"

# ---- 1. Create the API. Backend audience is https://ai.azure.com (Anthropic on Foundry),
#         NOT cognitiveservices.azure.com (that is Azure-OpenAI only). ----
az apim api create `
  --resource-group $ResourceGroup --service-name $ApimName `
  --api-id "claude-anthropic" --display-name "Claude (Anthropic Messages)" `
  --path "anthropic" --protocols https `
  --service-url "https://$FoundryResourceName.services.ai.azure.com/anthropic" `
  --subscription-required false | Out-Null
Write-Host "Created API claude-anthropic -> https://$FoundryResourceName.services.ai.azure.com/anthropic"

# ---- 1b. Create the named backend the policy routes to (backend-id must be 'foundry-claude'
#          to match <set-backend-service backend-id="foundry-claude" /> in 04-apim-policy.xml). ----
az apim backend create `
  --resource-group $ResourceGroup --service-name $ApimName `
  --backend-id "foundry-claude" --protocol http `
  --url "https://$FoundryResourceName.services.ai.azure.com/anthropic" | Out-Null
Write-Host "Created backend foundry-claude"

# ---- 2. Add the POST /v1/messages operation. ----
az apim api operation create `
  --resource-group $ResourceGroup --service-name $ApimName `
  --api-id "claude-anthropic" --operation-id "messages" `
  --display-name "Create message" --method POST --url-template "/v1/messages" | Out-Null
Write-Host "Added operation POST /v1/messages"

# ---- 3. Grant the APIM managed identity the Foundry data-plane role on the Foundry resource.
#         The role is "Cognitive Services User" - also surfaced as "Foundry User"
#         (formerly "Azure AI User"); confirm the exact display name in your tenant.
#         The policy authenticates to the backend with audience https://ai.azure.com. ----
$foundryScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CognitiveServices/accounts/$FoundryResourceName"
az role assignment create `
  --assignee-object-id $ApimPrincipalId --assignee-principal-type ServicePrincipal `
  --role "Cognitive Services User" --scope $foundryScope | Out-Null
Write-Host "Granted the APIM MI ($ApimPrincipalId) the Foundry data-plane role"

# ---- 4. Apply the policy via ARM REST. Body MUST be UTF-8 WITHOUT a BOM or az rest fails. ----
$policyXml = Get-Content -Path $PolicyFile -Raw
$policyBody = @{ properties = @{ format = "rawxml"; value = $policyXml } } | ConvertTo-Json -Depth 5
$tmp = New-TemporaryFile
[System.IO.File]::WriteAllText($tmp, $policyBody, (New-Object System.Text.UTF8Encoding($false)))  # $false = no BOM
$policyUrl = "$base/apis/claude-anthropic/policies/policy?api-version=$ApiVersion"
az rest --method PUT --url $policyUrl --headers "Content-Type=application/json" --body "@$tmp" | Out-Null
Remove-Item $tmp -Force
Write-Host "Applied 04-apim-policy.xml to claude-anthropic"

Write-Host ""
Write-Host "Backend wired. Next: 05-enable-diagnostics.ps1, then configure the client (06/07) and test with 08-sample-agent.ps1."
