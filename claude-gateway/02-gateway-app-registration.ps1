<#
=============================================================================
 Pattern B - Gateway app registration (NO admin consent required)
-----------------------------------------------------------------------------
 WHAT THIS DOES
   Creates the Entra app registration that the APIM gateway validates tokens
   against, WITHOUT needing a tenant admin to grant consent. The trick: the app
   pre-authorizes the Azure CLI public client, so a developer who runs
   `az account get-access-token --scope api://<GATEWAY_APP_ID>/.default` gets a
   token for this API with no consent prompt. The app also exposes a Claude.User
   app role; only users assigned that role can call the gateway.

   Steps, all via Microsoft Graph (az rest):
     1. Create the app: v2 access tokens, one delegated scope (user_impersonation),
        pre-authorize the Azure CLI client for that scope, one app role (Claude.User).
     2. PATCH the identifierUris to api://<APP_ID> (must be a second call - the URI
        cannot be set before the app, and therefore its appId, exists).
     3. Create the service principal for the app.
     4. Assign a human user to the Claude.User role.

   The developer then mints a gateway token with:
     az account get-access-token --scope api://<GATEWAY_APP_ID>/.default
   which yields aud=<GATEWAY_APP_ID>, scp=user_impersonation, roles=Claude.User, oid=<the user>.

 PREREQUISITES / ROLES
   - Azure CLI signed in as someone who can create app registrations (Application
     Developer is enough; no Global Admin, no admin consent).
   - The scope and role GUIDs are generated fresh at runtime - do not hard-code them.

 PLACEHOLDERS TO FILL (parameters)
   -DisplayName   Friendly name for the app registration.
   -AssignUserOid Object id of the human to grant Claude.User (defaults to the signed-in user).
=============================================================================
#>

param(
  [string]$DisplayName = "Claude Gateway",
  [string]$AssignUserOid = ""   # defaults to the signed-in user if left blank
)

$ErrorActionPreference = "Stop"
$graph = "https://graph.microsoft.com/v1.0"

# Azure CLI public client id. This is a well-known, tenant-independent Microsoft constant
# (the Azure CLI first-party app). Pre-authorizing it is what removes the consent prompt.
$AZURE_CLI_CLIENT_ID = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"

# Fresh GUIDs for the delegated scope and the app role.
$scopeId = [guid]::NewGuid().ToString()
$roleId  = [guid]::NewGuid().ToString()

# ---- 1. Create the app registration. -----------------------------------------
$appBody = @{
  displayName    = $DisplayName
  signInAudience = "AzureADMyOrg"
  api = @{
    requestedAccessTokenVersion = 2
    oauth2PermissionScopes = @(@{
      id                      = $scopeId
      value                   = "user_impersonation"
      type                    = "User"
      isEnabled               = $true
      adminConsentDisplayName = "Access the Claude gateway as the signed-in user"
      adminConsentDescription = "Allows the app to call the Claude gateway on behalf of the signed-in user."
      userConsentDisplayName  = "Access the Claude gateway on your behalf"
      userConsentDescription  = "Allows the app to call the Claude gateway as you."
    })
    preAuthorizedApplications = @(@{
      appId                  = $AZURE_CLI_CLIENT_ID
      delegatedPermissionIds = @($scopeId)
    })
  }
  appRoles = @(@{
    id                 = $roleId
    value              = "Claude.User"
    displayName        = "Claude.User"
    description        = "Can call the Claude gateway."
    allowedMemberTypes = @("User")
    isEnabled          = $true
  })
} | ConvertTo-Json -Depth 10

$app = az rest --method POST --url "$graph/applications" `
  --headers "Content-Type=application/json" --body $appBody | ConvertFrom-Json
$appObjectId = $app.id
$appId       = $app.appId
Write-Host "Created app: appId=$appId (objectId=$appObjectId)"

# ---- 2. Set the identifier URI to api://<APP_ID> (needs the appId, so it is a 2nd call). ----
$patch = @{ identifierUris = @("api://$appId") } | ConvertTo-Json
az rest --method PATCH --url "$graph/applications/$appObjectId" `
  --headers "Content-Type=application/json" --body $patch | Out-Null
Write-Host "Set identifierUris = api://$appId"

# ---- 3. Create the service principal for the app. ----------------------------
$sp = az rest --method POST --url "$graph/servicePrincipals" `
  --headers "Content-Type=application/json" `
  --body (@{ appId = $appId } | ConvertTo-Json) | ConvertFrom-Json
$spId = $sp.id
Write-Host "Created service principal: id=$spId"

# ---- 4. Assign a human user to the Claude.User app role. ----------------------
if ([string]::IsNullOrEmpty($AssignUserOid)) {
  $AssignUserOid = az ad signed-in-user show --query id -o tsv
}
$assign = @{ principalId = $AssignUserOid; resourceId = $spId; appRoleId = $roleId } | ConvertTo-Json
az rest --method POST --url "$graph/users/$AssignUserOid/appRoleAssignments" `
  --headers "Content-Type=application/json" --body $assign | Out-Null
Write-Host "Assigned Claude.User to user $AssignUserOid"

Write-Host ""
Write-Host "==== Values for the policy and client config ===="
Write-Host "GATEWAY_APP_ID (aud, bare GUID) : $appId"
Write-Host "GATEWAY_APP_ID_URI              : api://$appId"
Write-Host "CLIENT SCOPE for token mint     : api://$appId/.default"
Write-Host "Fill <GATEWAY_APP_ID> in 04-apim-policy.xml, 06-claude-code-settings.json, 07-apikeyhelper.sh, 08-sample-agent.ps1"
