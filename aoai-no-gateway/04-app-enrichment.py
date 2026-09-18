"""
Pattern A - OPTIONAL app-side ENRICHMENT (not the source of truth).

WHAT THIS DOES
    The platform diagnostic log is the meter for identity + tokens. This snippet
    adds the two dimensions the platform log cannot give you:
      1. the client APPLICATION identity (so you get user AND app, not just the caller),
      2. business context (cost center, logical app name, session/transaction id).

    It writes ONE enrichment record per call, keyed by the apim-request-id response
    header, which equals the diagnostic CorrelationId (pilot-observed). You later
    LEFT JOIN this enrichment onto the platform rows on that key. If this write fails,
    you lose enrichment, never the meter - the platform log still counted the tokens
    and the caller.

    Do NOT treat the token counts or the user id written here as authoritative; they
    are for cross-checking only. The authoritative identity + tokens come from
    AzureDiagnostics (see 02-attribution.kql).

PREREQUISITES
    - Packages: azure-identity, azure-monitor-ingestion, openai.
    - A custom table + DCE + DCR from 07-enrichment-table-dcr.bicep.
    - Only needed if you want the user-AND-app view, or you call as a shared identity.

PLACEHOLDERS TO FILL
    <FOUNDRY_RESOURCE_NAME>  Azure OpenAI / Foundry account name.
    <DEPLOYMENT_NAME>        The chat deployment name.
    <REGION>                 Azure region of the data collection endpoint.
    plus the app id / app name / cost center / DCR immutable id noted inline.
"""
from azure.identity import DefaultAzureCredential
from azure.monitor.ingestion import LogsIngestionClient
from openai import AzureOpenAI

# --- 1. Call Azure OpenAI as the signed-in user (interactive/OBO) OR as the app (MI/SP). ---
# For per-HUMAN attribution in the platform log, the token presented to Azure OpenAI must be
# the user's (interactive or On-Behalf-Of). If you call as a managed identity, the platform
# log's callerObjectId is the MI, and the human is known ONLY here in the app.
token_provider = DefaultAzureCredential()
client = AzureOpenAI(
    azure_endpoint="https://<FOUNDRY_RESOURCE_NAME>.cognitiveservices.azure.com",
    azure_ad_token_provider=lambda: token_provider.get_token(
        "https://cognitiveservices.azure.com/.default").token,
    api_version="2025-01-01-preview",
)

resp = client.chat.completions.with_raw_response.create(
    model="<DEPLOYMENT_NAME>",
    messages=[{"role": "user", "content": "..."}],
    # For streaming, you MUST set stream_options={"include_usage": True} or usage is absent.
)
parsed = resp.parse()

# --- 2. Capture the join key (apim-request-id header == diagnostic CorrelationId). ---
apim_request_id = resp.headers.get("apim-request-id")

# --- 3. Build the enrichment record. Identity of the app comes from the app's OWN
#        authenticated context (its client/app id), NOT a value the caller can type. ---
enrichment = {
    "TimeGenerated": None,               # set by the ingestion pipeline / DCR transform
    "CorrelationId": apim_request_id,    # join key to AzureDiagnostics
    "AppId": "<CLIENT_APP_ID>",          # the application's own identity (from its config/MI)
    "AppName": "<LOGICAL_APP_NAME>",     # resolve centrally, not per-request free text
    "CostCenter": "<FROM_GOVERNED_MAP>", # map AppId/oid -> cost center in a governed table, effective-dated
    "SignedInUserOid": "<USER_OID_IF_KNOWN>",  # cross-check only; platform log is authoritative
    "SessionId": "<BUSINESS_TRANSACTION_ID>",
    # cross-check tokens (authoritative counts live in AzureDiagnostics):
    #   prompt_tokens INCLUDES cached_tokens -> billable input = prompt - cached (never add cached on top).
    #   reasoning_tokens are a SUBSET of completion_tokens -> already billed as output; never a separate line.
    "xcheck_prompt_tokens": parsed.usage.prompt_tokens,
    "xcheck_completion_tokens": parsed.usage.completion_tokens,
    "xcheck_cached_tokens": getattr(parsed.usage.prompt_tokens_details, "cached_tokens", 0),
    # reasoning/cache_write are model-conditional - read defensively, do not assume present.
    # Azure OpenAI cache WRITES are billed on GPT-5.6+ (prompt_tokens_details.cache_write_tokens);
    # older models have no cache-write charge and this defaults to 0 (backward-safe).
    "xcheck_cache_write_tokens": getattr(parsed.usage.prompt_tokens_details, "cache_write_tokens", 0),
    "xcheck_reasoning_tokens": getattr(
        getattr(parsed.usage, "completion_tokens_details", None), "reasoning_tokens", None),
    # verbatim usage object, so a new meter never forces a re-capture:
    "rawUsage": parsed.usage.model_dump_json() if hasattr(parsed.usage, "model_dump_json") else str(parsed.usage),
}

# --- 3b. Integrity gates (fail LOUD, do not silently mis-bill). cached is a subset of prompt;
#        reasoning is a subset of completion. A violation means the meter shape changed. ---
_cached = enrichment["xcheck_cached_tokens"] or 0
_reason = enrichment["xcheck_reasoning_tokens"] or 0
assert _cached <= parsed.usage.prompt_tokens, "cached_tokens > prompt_tokens - meter shape changed"
assert _reason <= parsed.usage.completion_tokens, "reasoning_tokens > completion_tokens - would double-count"

# --- 4. Send to a Log Analytics CUSTOM TABLE via the Logs Ingestion API + DCR.
#        (The legacy HTTP Data Collector API retired 2026-09-14 - do not use it.)
#        Use the Analytics table plan (you will JOIN this and export to the portal / Power BI). ---
ingest = LogsIngestionClient(endpoint="https://<DCE_NAME>.<REGION>.ingest.monitor.azure.com",
                             credential=token_provider)
ingest.upload(rule_id="<DCR_IMMUTABLE_ID>",
              stream_name="Custom-AoaiEnrichment_CL",
              logs=[enrichment])

# Reliability: buffer/outbox this write (fail-open on the inference path). Losing an
# enrichment row must reduce COVERAGE visibly, not silently lower anyone's charge.
