# Data model: the tables, where they come from, and how they join

This page shows every table and file the toolkit touches, which ones **already exist** in Azure
versus which the toolkit **creates**, their schemas, and the keys that join them. If you only read
one diagram, read the first.

## What is native vs what the toolkit creates

| Store | Kind | Native or created? | Used by |
|---|---|---|---|
| `AzureDiagnostics` — `RequestResponse` rows | Log Analytics (shared table) | **Native** (you enable the diagnostic category) | Pattern A attribution |
| `AzureDiagnostics` — `AzureOpenAIRequestUsage` rows | Log Analytics (shared table) | **Native** | Pattern A cached-token subset |
| `ApiManagementGatewayLlmLog` | Log Analytics | **Native** (you enable the APIM diagnostic) | Pattern B per-user tokens |
| `ApiManagementGatewayLogs` | Log Analytics | **Native** | Pattern B — carries the stamped `x-caller-oid` |
| `AoaiEnrichment_CL` | Log Analytics **custom table** | **Created** by `aoai-no-gateway/07-enrichment-table-dcr.bicep` | Pattern A app-context cross-check (join by `CorrelationId`) |
| `AiSpendEnrichment_CL` | Log Analytics **custom table** | **Created** by `portal/enrichment-table-dcr.bicep` | The portal's rich dept/app/user store (read directly) |
| Rate card CSV | File you own | **You provide** | Pricing, in `lib/AiBilling.Metering.psm1` |
| `portal/data.json` | File | **Generated** by `query-helper.ps1` | The portal reads it (git-ignored; holds live identity data) |

The toolkit **creates only the two `_CL` custom tables**, and both are **optional** — the native
logs alone give you attribution. You never modify the native `AzureDiagnostics` /
`ApiManagement*` tables; you only turn their diagnostic categories on.

## The whole picture

```mermaid
flowchart TD
  subgraph native["Native Azure telemetry (you enable the categories)"]
    RR["AzureDiagnostics<br/>RequestResponse<br/>(callerObjectId, tokens)"]
    USG["AzureDiagnostics<br/>AzureOpenAIRequestUsage<br/>(cachedTokens)"]
    LLM["ApiManagementGatewayLlmLog<br/>(prompt/completion tokens)"]
    GWL["ApiManagementGatewayLogs<br/>(x-caller-oid header)"]
  end
  subgraph created["Custom tables the toolkit creates (optional)"]
    AOAIENR["AoaiEnrichment_CL<br/>app context, xcheck tokens<br/>(07-bicep)"]
    SPEND["AiSpendEnrichment_CL<br/>dept/app/user + all meters<br/>(portal bicep + write-spend-record.ps1)"]
  end
  RATE[("Rate card CSV<br/>you own")]
  APP2["Your app / write-spend-record.ps1"] -->|"Logs Ingestion API"| SPEND

  RR -->|"CorrelationId"| DATA["query-helper.ps1<br/>+ lib/AiBilling.Metering.psm1"]
  USG -->|"CorrelationId join"| DATA
  AOAIENR -.->|"CorrelationId join (optional)"| DATA
  LLM -->|"CorrelationId"| DATA
  GWL -->|"CorrelationId join"| DATA
  SPEND -->|"read directly (preferred)"| DATA
  RATE --> DATA
  DATA --> JSON[("portal/data.json")]
  JSON --> PORTAL["portal/index.html"]
  CM[("Cost Management /<br/>Marketplace meter")] -.->|"reconcile"| PORTAL
```

The query-helper prefers `AiSpendEnrichment_CL` when it exists (full dept/app/user drill). If it
is absent, it falls back to the native `RequestResponse` (+ `AzureOpenAIRequestUsage`) and
`ApiManagementGatewayLlmLog` (+ `ApiManagementGatewayLogs`) and attributes per principal.

## The join key everything hangs on

Every cross-table link in this toolkit is the same key: **`CorrelationId`**. What is *documented*
versus *pilot-observed* differs by pattern — be precise with a reviewer:

- **Pattern B (documented, first-party).** `ApiManagementGatewayLlmLog.CorrelationId` equals
  `ApiManagementGatewayLogs.CorrelationId` — the LlmLog reference literally defines its
  `CorrelationId` as the same field in `ApiManagementGatewayLogs`. So joining per-user tokens to
  the stamped identity is a supported, documented join. **Caveat:** `ApiManagementGatewayLogs` does
  **not** capture arbitrary request headers by default — the `x-caller-oid` header only appears if
  the API's diagnostic setting is configured to log it. `claude-gateway/05-enable-diagnostics.ps1`
  configures exactly that; if you skip it, the oid is absent.
- **Pattern A (pilot-observed, not contracted).** That `RequestResponse` carries `callerObjectId`
  and per-request token counts inside `properties_s`, and that its `CorrelationId` equals the
  **`apim-request-id` response header** the caller sees, are **not** in any first-party schema.
  They work today and are load-bearing, but Microsoft can change them — the canary
  (`aoai-no-gateway/06-canary-schema-drift.kql`) guards them. See
  `docs/05-operations-and-gotchas.md`.

```mermaid
erDiagram
  RequestResponse ||--o| AzureOpenAIRequestUsage : "CorrelationId"
  RequestResponse ||--o| AoaiEnrichment_CL : "CorrelationId (optional app context)"
  ApiManagementGatewayLlmLog ||--|| ApiManagementGatewayLogs : "CorrelationId (-> x-caller-oid)"

  RequestResponse {
    string CorrelationId "== apim-request-id"
    string callerObjectId "the caller oid (pilot-observed)"
    long promptTokens
    long completionTokens
    string modelName
    string modelDeploymentName
  }
  AzureOpenAIRequestUsage {
    string CorrelationId
    long promptTokens
    long cachedTokens "subset of prompt"
    long generatedTokens
  }
  AoaiEnrichment_CL {
    string CorrelationId "join key"
    string AppId
    string AppName
    string CostCenter
    string SignedInUserOid "cross-check only"
    int xcheck_prompt_tokens
    int xcheck_completion_tokens
    int xcheck_cached_tokens
    int xcheck_reasoning_tokens
    string rawUsage
  }
  ApiManagementGatewayLlmLog {
    string CorrelationId
    string DeploymentName
    long PromptTokens
    long CompletionTokens
  }
  ApiManagementGatewayLogs {
    string CorrelationId
    string RequestHeaders "carries x-caller-oid"
  }
```

## The portal's spend store (the one that powers the drill-down)

`AiSpendEnrichment_CL` is a **standalone record per call** — the portal reads it directly, no join.
It is how you get department → app → user and the full cache/thinking meters for both patterns.
Its data path has **three shipped halves**, so you can prove it end to end:

1. **Create** the table + DCE + DCR — `portal/enrichment-table-dcr.bicep`.
2. **Write** records — `portal/write-spend-record.ps1` (a reference writer: send a JSON array, or
   emit one demo record to prove the loop). In production your application emits one record per
   call from its own governed context; this script is the reference pattern.
3. **Read** — `portal/query-helper.ps1` prefers this table and flattens it into `data.json`.

The rich dept/app/user view is **optional**: without this table the portal falls back to
per-principal attribution from the native logs. It stays empty until something writes records — the
reference writer exists so "wire the enrichment path" is a runnable step, not an unimplemented TODO.

Records use this shape (the app emits it; department / app / cost-center come from a governed
context, never caller input):

```mermaid
erDiagram
  AiSpendEnrichment_CL {
    datetime TimeGenerated "call time"
    string oid "principal Entra object id"
    string userName "display name (enrichment)"
    string department "from a governed map, not caller input"
    string app "logical application"
    string pipeline "aoai | gateway"
    string model "model / deployment"
    int inputTokens "ALREADY-UNCACHED input (both families)"
    int outputTokens "includes thinking"
    int cacheWriteTokens "Claude cache-creation total (0 for AOAI)"
    int cacheReadTokens "cache read / AOAI cached subset"
    int thinkingTokens "subset of output - never priced"
    real estCost "optional; portal re-prices from the rate card"
    string correlationId "optional dedup / join key"
  }
```

**Two enrichment tables, two jobs — the trust boundary is decisive, do not blur it:**

| | `AoaiEnrichment_CL` (07-bicep) | `AiSpendEnrichment_CL` (portal bicep) |
|---|---|---|
| Purpose | Add **app context** (AppId / cost center) to the native Pattern A log | A **complete spend record** the portal reads directly |
| How it's used | **JOINed** onto `RequestResponse` by `CorrelationId`; the native log stays authoritative for tokens/identity | **Read standalone**; it is authoritative for its own records |
| Token columns | `xcheck_*` — **cross-check only**, never priced from | The authoritative per-record meters, priced by the portal |
| Covers | Pattern A | Both patterns (aoai + gateway) |
| Required? | Optional | Optional (portal falls back to native logs) |

They are **never joined or unioned to each other** — one adds context to the native meter, the
other *is* the meter for its records. Mixing them would double-count. Pick one enrichment strategy
per deployment.

## The portal's `data.json` contract (generated, not a table)

`query-helper.ps1` flattens whichever source it used into one array the portal renders. It is
git-ignored because it holds live identity data.

```
{
  generatedAt, timeRangeHours,
  source: "enrichment" | "platform-log",   // which store produced the records
  queryOk: <bool>,                          // false => a query FAILED (portal shows a red banner, not $0)
  records: [ {
    ts, oid, user, department, app, pipeline, model,
    input, output, cacheWrite, cacheRead, thinking,   // integers or null (null = meter not on this path)
    cost, costBasis                                    // cost null = UNPRICED (never $0); basis full|p+c-only|unpriced
  } ]
}
```

## Pricing input (a file you own, not a table)

The rate card (`aoai-no-gateway/03-pricing-table.sample.csv`) is effective-dated and kept out of
any repo for real prices. `lib/AiBilling.Metering.psm1` is the single place that turns meters into
dollars, and `acceptance/run-acceptance.ps1` guards that math. Columns: `model`, `input_per_1m`,
`cached_input_per_1m` (AOAI), `output_per_1m`, `cache_write_5m_per_1m`, `cache_write_1h_per_1m`,
`cache_read_per_1m` (Claude), and `valid_from` / `valid_to` for effective dating.

## See also

- `docs/01-how-it-works.md` — the identity/token semantics behind these fields.
- `docs/02-setup-aoai-no-gateway.md` / `docs/03-setup-claude-gateway.md` — how the native logs get
  enabled and queried.
- `docs/04-portal.md` — how the portal consumes `data.json`.
- `docs/05-operations-and-gotchas.md` — the pilot-observed-field risk, retention, and teardown.
