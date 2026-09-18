// =============================================================================
// Pattern A - OPTIONAL app-side ENRICHMENT (C#). Parallel to 04-app-enrichment.py.
// -----------------------------------------------------------------------------
// WHAT THIS DOES
//   The platform diagnostic log is the meter for identity + tokens. This adds the
//   client APPLICATION identity + business context, keyed by the apim-request-id
//   response header (== diagnostic CorrelationId, pilot-observed). It is NOT the
//   source of truth for oid/tokens.
//
// PREREQUISITES
//   - Packages: Azure.AI.OpenAI (v2), Azure.Identity, Azure.Monitor.Ingestion.
//   - A custom table + DCE + DCR from 07-enrichment-table-dcr.bicep.
//   - Property names vary slightly by SDK version; verify against the version you pin.
//
// PLACEHOLDERS TO FILL
//   <FOUNDRY_RESOURCE_NAME>  Azure OpenAI / Foundry account name.
//   <DEPLOYMENT_NAME>        The chat deployment name.
//   <REGION>                 Azure region of the data collection endpoint.
//   plus the app id / app name / cost center / DCR immutable id noted inline.
// =============================================================================

using Azure.AI.OpenAI;
using Azure.Identity;
using Azure.Monitor.Ingestion;
using OpenAI.Chat;

var credential = new DefaultAzureCredential();

// 1. Call Azure OpenAI. For per-HUMAN attribution in the platform log, the token presented must be
//    the user's (interactive/OBO). Calling as a managed identity logs the MI as callerObjectId.
var aoai = new AzureOpenAIClient(
    new Uri("https://<FOUNDRY_RESOURCE_NAME>.cognitiveservices.azure.com"), credential);
ChatClient chat = aoai.GetChatClient("<DEPLOYMENT_NAME>");

// Use the protocol/raw path so we can read response headers.
ClientResult<ChatCompletion> result = await chat.CompleteChatAsync(
    new[] { new UserChatMessage("...") });
ChatCompletion completion = result.Value;

// 2. Capture the join key from the response header.
string? apimRequestId = null;
if (result.GetRawResponse().Headers.TryGetValue("apim-request-id", out var hdr))
    apimRequestId = hdr;

// 3. Build the enrichment record. App identity comes from the app's OWN config/identity,
//    never a value the caller types. Cost center comes from a governed map, effective-dated.
var record = new Dictionary<string, object?>
{
    ["TimeGenerated"] = DateTime.UtcNow.ToString("o"),
    ["CorrelationId"] = apimRequestId,          // join to AzureDiagnostics
    ["AppId"] = "<CLIENT_APP_ID>",
    ["AppName"] = "<LOGICAL_APP_NAME>",
    ["CostCenter"] = "<FROM_GOVERNED_MAP>",
    ["SignedInUserOid"] = "<USER_OID_IF_KNOWN>",   // cross-check only
    ["SessionId"] = "<BUSINESS_TRANSACTION_ID>",
    // cross-check counts (authoritative counts live in AzureDiagnostics):
    //   InputTokenCount INCLUDES cached tokens -> billable input = input - cached (never add cached on top).
    //   reasoning tokens are a SUBSET of output -> already billed as output; never a separate line.
    ["xcheck_prompt_tokens"] = completion.Usage.InputTokenCount,
    ["xcheck_completion_tokens"] = completion.Usage.OutputTokenCount,
    // cached / reasoning are model-conditional - read defensively (property path varies by SDK).
    // Azure OpenAI cache WRITES are billed on GPT-5.6+ (cache_write_tokens); older models have no
    // cache-write charge and it defaults to 0 (backward-safe). Property name varies by SDK version.
    ["xcheck_cached_tokens"] = completion.Usage.InputTokenDetails?.CachedTokenCount ?? 0,
    ["xcheck_reasoning_tokens"] = completion.Usage.OutputTokenDetails?.ReasoningTokenCount ?? 0,
    // verbatim usage object, so a new meter never forces a re-capture:
    ["rawUsage"] = System.Text.Json.JsonSerializer.Serialize(completion.Usage),
};

// 3b. Integrity gates (fail LOUD, never silently mis-bill): cached is a subset of prompt;
//     reasoning is a subset of completion. A violation means the meter shape changed.
long cachedX = completion.Usage.InputTokenDetails?.CachedTokenCount ?? 0;
long reasonX = completion.Usage.OutputTokenDetails?.ReasoningTokenCount ?? 0;
if (cachedX > completion.Usage.InputTokenCount)
    throw new InvalidOperationException("cached_tokens > prompt_tokens - meter shape changed");
if (reasonX > completion.Usage.OutputTokenCount)
    throw new InvalidOperationException("reasoning_tokens > completion_tokens - would double-count");

// 4. Send to the Log Analytics custom table via the Logs Ingestion API + DCR (see 07-*.bicep).
var ingest = new LogsIngestionClient(
    new Uri("https://<DCE_NAME>.<REGION>.ingest.monitor.azure.com"), credential);
await ingest.UploadAsync(
    ruleId: "<DCR_IMMUTABLE_ID>",
    streamName: "Custom-AoaiEnrichment_CL",
    logs: new[] { record });

// Reliability: buffer/outbox this write and fail OPEN on the inference path.
// A lost enrichment row must reduce COVERAGE visibly, never silently lower a charge.
