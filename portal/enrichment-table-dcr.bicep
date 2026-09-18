// =============================================================================
// Portal spend-record store: custom table + DCE + DCR for AiSpendEnrichment_CL
// -----------------------------------------------------------------------------
// WHAT THIS DOES
//   Creates the Log Analytics custom table the PORTAL prefers as its rich source:
//   one self-contained SPEND RECORD per call carrying department / app / user and
//   every token meter. Unlike aoai-no-gateway/07-enrichment-table-dcr.bicep (which
//   creates AoaiEnrichment_CL - app-context cross-check that JOINS onto the native
//   Pattern A log by CorrelationId), this table is a STANDALONE record the portal
//   reads directly, so it can show the department -> app -> user drill-down and the
//   full cache/thinking meters for BOTH patterns.
//
//   The portal works WITHOUT this table (it falls back to the native platform +
//   gateway logs, attributing per principal with no dept/app/user). Deploy this only
//   if you want the enriched drill-down view. Whatever writes records here (your app,
//   or an ingestion adapter over claude-gateway/08-sample-agent output) must set
//   department / app / cost-center from its OWN governed context, never caller input,
//   and a lost write must reduce COVERAGE visibly - never silently lower a charge.
//
//   Token convention: inputTokens is ALREADY-UNCACHED input for both families
//   (Claude input_tokens; Azure OpenAI prompt - cached). See docs/01-how-it-works.md.
//
// PREREQUISITES / ROLES
//   - An existing Log Analytics workspace.
//   - Rights to deploy this Bicep (Contributor on the resource group) and to assign
//     Monitoring Metrics Publisher on the DCR (the template assigns it for you).
//   - Deploy: az deployment group create -g <RESOURCE_GROUP> --template-file portal/enrichment-table-dcr.bicep \
//               --parameters workspaceName=<LOG_ANALYTICS_WORKSPACE_NAME> senderPrincipalId=<SENDER_PRINCIPAL_ID>
//     Output: the DCE logs-ingestion endpoint and the DCR immutableId (you POST records to these).
//
// PLACEHOLDERS TO FILL (parameters below)
//   workspaceName      Existing Log Analytics workspace name.
//   senderPrincipalId  Object id of the app identity (MI or SP, or the signed-in user)
//                      that sends spend records via the Logs Ingestion API.
// =============================================================================

@description('Existing Log Analytics workspace name.')
param workspaceName string

@description('Location for the DCE/DCR (match the workspace region for residency).')
param location string = resourceGroup().location

@description('Object id of the identity that will send spend records to the Logs Ingestion API.')
param senderPrincipalId string

var dceName = 'dce-aispend'
var dcrName = 'dcr-aispend'
var tableName = 'AiSpendEnrichment_CL'
var streamName = 'Custom-AiSpendEnrichment_CL'

// The one schema, shared by the table, the DCR stream, and the portal's query-helper.
var columns = [
  { name: 'TimeGenerated', type: 'datetime' }      // required by Log Analytics; the call time
  { name: 'oid', type: 'string' }                  // the human/principal Entra object id
  { name: 'userName', type: 'string' }             // display name (enrichment)
  { name: 'department', type: 'string' }           // from a governed map, not caller input
  { name: 'app', type: 'string' }                  // logical application name
  { name: 'pipeline', type: 'string' }             // "aoai" | "gateway"
  { name: 'model', type: 'string' }                // model / deployment
  { name: 'inputTokens', type: 'int' }             // ALREADY-UNCACHED input (both families)
  { name: 'outputTokens', type: 'int' }            // output (includes thinking)
  { name: 'cacheWriteTokens', type: 'int' }        // Claude cache-creation total (0/absent for AOAI)
  { name: 'cacheReadTokens', type: 'int' }         // cache read (AOAI cached subset, or Claude cache-read)
  { name: 'thinkingTokens', type: 'int' }          // subset of output - display only, never priced
  { name: 'estCost', type: 'real' }                // optional; the portal re-prices from the rate card
  { name: 'correlationId', type: 'string' }        // optional dedup / join key (apim-request-id)
]

resource ws 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

// Custom table (Analytics plan - the portal JOINs/aggregates and exports).
resource table 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: ws
  name: tableName
  properties: {
    schema: {
      name: tableName
      columns: columns
    }
    retentionInDays: 90
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  properties: {
    networkAcls: { publicNetworkAccess: 'Enabled' } // set to 'Disabled' + private link for a bank
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${streamName}': {
        columns: columns
      }
    }
    destinations: {
      logAnalytics: [
        { name: 'la', workspaceResourceId: ws.id }
      ]
    }
    dataFlows: [
      {
        streams: [ streamName ]
        destinations: [ 'la' ]
        transformKql: 'source'
        outputStream: 'Custom-${tableName}'
      }
    ]
  }
}

// Grant the sender the right to publish to this DCR (Monitoring Metrics Publisher).
resource publisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, senderPrincipalId, 'Monitoring Metrics Publisher')
  scope: dcr
  properties: {
    // Monitoring Metrics Publisher
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId: senderPrincipalId
    principalType: 'ServicePrincipal' // use 'User' if senderPrincipalId is a signed-in user
  }
}

output dceLogsIngestionEndpoint string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
output streamName string = streamName
output tableName string = tableName
