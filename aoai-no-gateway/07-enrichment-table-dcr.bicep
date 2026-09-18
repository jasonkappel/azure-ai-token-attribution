// =============================================================================
// Pattern A - OPTIONAL enrichment pipeline: custom table + DCE + DCR (Logs Ingestion API)
// -----------------------------------------------------------------------------
// WHAT THIS DOES
//   Stands up the Log Analytics custom table and the Data Collection Endpoint /
//   Rule that back 04-app-enrichment.py and 09-app-enrichment.cs. This is NOT the
//   meter. The meter is the native Azure OpenAI diagnostic log. This table only adds
//   the client APPLICATION identity and business context (cost center, app name),
//   joined to the platform rows on CorrelationId (== the apim-request-id response
//   header). The legacy HTTP Data Collector API retired 2026-09-14; this uses the
//   current Logs Ingestion API pattern.
//
// PREREQUISITES / ROLES
//   - An existing Log Analytics workspace.
//   - Rights to deploy this Bicep (Contributor on the resource group) and to assign
//     the Monitoring Metrics Publisher role on the DCR.
//   - Deploy: az deployment group create -g <RESOURCE_GROUP> --template-file 07-enrichment-table-dcr.bicep \
//               --parameters workspaceName=<LOG_ANALYTICS_WORKSPACE_NAME> senderPrincipalId=<SENDER_PRINCIPAL_ID>
//
// PLACEHOLDERS TO FILL (parameters below)
//   workspaceName      Existing Log Analytics workspace name.
//   senderPrincipalId  Object id of the app identity (MI or SP) that sends enrichment records.
// =============================================================================

@description('Existing Log Analytics workspace name.')
param workspaceName string

@description('Location for the DCE/DCR (match the workspace region for residency).')
param location string = resourceGroup().location

@description('Object id of the app identity (managed identity or SP) that will send enrichment records.')
param senderPrincipalId string

var dceName = 'dce-aoai-enrichment'
var dcrName = 'dcr-aoai-enrichment'
var tableName = 'AoaiEnrichment_CL'
var streamName = 'Custom-AoaiEnrichment_CL'

resource ws 'Microsoft.OperationalInsights/workspaces@2022-10-01' existing = {
  name: workspaceName
}

// Custom table (Analytics plan by default - required because we JOIN and export to the portal / Power BI).
resource table 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: ws
  name: tableName
  properties: {
    schema: {
      name: tableName
      columns: [
        { name: 'TimeGenerated', type: 'datetime' }
        { name: 'CorrelationId', type: 'string' }      // join key to AzureDiagnostics (apim-request-id)
        { name: 'AppId', type: 'string' }              // the client application's own identity
        { name: 'AppName', type: 'string' }
        { name: 'CostCenter', type: 'string' }         // resolved from a governed map, not caller input
        { name: 'SignedInUserOid', type: 'string' }    // cross-check only; platform log is authoritative
        { name: 'SessionId', type: 'string' }
        { name: 'xcheck_prompt_tokens', type: 'int' }
        { name: 'xcheck_completion_tokens', type: 'int' }
        { name: 'xcheck_cached_tokens', type: 'int' }      // AOAI cached (read) SUBSET of prompt; GPT-5.6+ also bills cache_write_tokens
        { name: 'xcheck_reasoning_tokens', type: 'int' }   // SUBSET of completion - display only, never a separate charge
        { name: 'rawUsage', type: 'string' }               // verbatim usage JSON, so a new meter needs no schema change
        // For an app-side CLAUDE capture store (non-streaming), add: cache_write_5m, cache_write_1h,
        // cache_read, thinking (all int). Claude input is already uncached; total input = input + write + read.
      ]
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
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'CorrelationId', type: 'string' }
          { name: 'AppId', type: 'string' }
          { name: 'AppName', type: 'string' }
          { name: 'CostCenter', type: 'string' }
          { name: 'SignedInUserOid', type: 'string' }
          { name: 'SessionId', type: 'string' }
          { name: 'xcheck_prompt_tokens', type: 'int' }
          { name: 'xcheck_completion_tokens', type: 'int' }
          { name: 'xcheck_cached_tokens', type: 'int' }
          { name: 'xcheck_reasoning_tokens', type: 'int' }
          { name: 'rawUsage', type: 'string' }
        ]
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
        transformKql: 'source'        // pass-through; app supplies TimeGenerated
        outputStream: streamName
      }
    ]
  }
  dependsOn: [ table ]
}

// The sender identity needs Monitoring Metrics Publisher on the DCR.
var monitoringMetricsPublisher = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
resource ra 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, senderPrincipalId, monitoringMetricsPublisher)
  scope: dcr
  properties: {
    roleDefinitionId: monitoringMetricsPublisher
    principalId: senderPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output dceIngestionEndpoint string = dce.properties.logsIngestion.endpoint
output dcrImmutableId string = dcr.properties.immutableId
output streamName string = streamName
