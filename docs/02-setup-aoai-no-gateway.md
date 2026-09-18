# Setup: Azure OpenAI attribution without a gateway (Pattern A)

This gets you per-principal token attribution and a list-price cost estimate for Azure
OpenAI, using only diagnostic logs, Log Analytics, and a rate card. No API Management, no
change to the calling app for the core meter.

## Before you begin

Read `docs/00-prerequisites.md` first (workstation tools, Azure/Entra rights, and the run order).
The two things people miss for Pattern A: you need **Log Analytics Reader on the workspace** (not
just Reader on the model resource) to query the logs, and the model must use **Entra auth with
keys off** — a shared-key call logs no principal, so there is nothing to attribute.

## Azure services you will use

| Service | Why | Notes |
|---|---|---|
| Azure OpenAI or Foundry (`Microsoft.CognitiveServices/accounts`) | The model you are attributing | Keys off (`disableLocalAuth=true`) so every call carries a principal |
| Log Analytics workspace (`Microsoft.OperationalInsights`) | Holds the diagnostic logs you query | Put it in an approved region for residency |
| Azure Monitor diagnostic settings | Routes the two log categories to the workspace | Set once per resource |
| Data Collection Endpoint + Rule (`Microsoft.Insights`) | Optional: the app-enrichment table | Only for the user-and-app view |
| Azure Cost Management | Reconciles the estimate to billed cost | Read access is enough |
| Power BI | Optional reporting alongside the portal in this repo | See `08-powerbi-setup.md` |

## Permissions you need

Roles are split by what you are doing. Least privilege: the person running queries does
not need the deploy roles.

| Task | Role | Scope |
|---|---|---|
| Turn keys off + create the diagnostic setting | Cognitive Services Contributor (or Contributor) and Monitoring Contributor | The Azure OpenAI / Foundry resource |
| Run the attribution queries (02, 06) | Log Analytics Reader | The workspace (grants `Microsoft.OperationalInsights/workspaces/query/read`) |
| Per-human native attribution | Cognitive Services OpenAI User (data-plane) | The model deployment, granted to the calling users |
| Deploy the enrichment table + DCR (07) | Contributor to deploy, plus User Access Administrator (or RBAC Administrator) to assign the role in the template | The resource group |
| Send enrichment records (the app identity) | Monitoring Metrics Publisher | The DCR (the Bicep assigns this for you) |
| Run the SP/MI verification (05) | Application Developer + a data-plane role assignment right | Tenant + the resource |
| Reconcile to billed cost | Cost Management Reader | The subscription or billing scope |

The single role most people forget: to run the KQL you need **Log Analytics Reader on the
workspace**, not just Reader on the resource. Reader on the Azure OpenAI account lets you see
the resource; it does not let you query its logs.

## One decision to make first

> **⛔ Clear the pilot gate first.** Do not run Step 1 until you have worked through
> `docs/06-pilot-decision-and-gate.md`. Step 1 turns on diagnostics that write employee-identifying
> object ids into the workspace — that needs privacy/DPIA sign-off and locked RBAC **before** the
> first row, not after.

Enabling `RequestResponse` writes every interactive caller's Entra object id into the
workspace. That is employee-identifying telemetry. Complete a privacy review or DPIA before
you do this in production, and restrict workspace RBAC so query access is deliberate.

## Step 1: turn keys off and enable diagnostics

Fill the placeholders in `aoai-no-gateway/01-enable-diagnostics.azcli`
(`<SUBSCRIPTION_ID>`, `<RESOURCE_GROUP>`, `<FOUNDRY_RESOURCE_NAME>`,
`<LOG_ANALYTICS_WORKSPACE_NAME>`) and run it.

It sets `disableLocalAuth=true` (a shared-key call logs no principal, so this is required)
and sends two categories to the workspace: `RequestResponse` (the attribution source) and
`AzureOpenAIRequestUsage` (the cached-token breakdown). Rows usually appear in 5 to 15
minutes on first enablement.

## Step 2: attribute and confirm one row per call

Open `aoai-no-gateway/02-attribution.kql` in the workspace and run Q1, then Q2. You should
see one attributed row per call, not two. If you see doubles, confirm the
`callerObjectId != ""` filter is doing its job (there are two `RequestResponse` rows per
call, one near-empty).

Q2 joins the cached-token subset from `AzureOpenAIRequestUsage` on `CorrelationId` and
computes billable input as `promptTokens - cachedInput`.

## Step 3: price it with a real rate card

The rate card in Q3 and in `03-pricing-table.sample.csv` uses illustrative public-list
placeholders. Replace them with your real, effective-dated rates. Keep the authoritative card
in a governed store, never negotiated or contract prices in a repo. Label the output as a
list-price estimate; it is not the invoice.

Watch two model-conditional details: on reasoning models, confirm whether reasoning tokens
are already inside `completionTokens` before pricing them again, and only price cache-write
when an invoice line exists for it.

## Step 4 (optional): add the user-and-app view

If you need user and app together, or your apps call as a shared identity, add app-side
enrichment:

1. Deploy the custom table and Data Collection Rule with
   `aoai-no-gateway/07-enrichment-table-dcr.bicep`
   (`az deployment group create -g <RESOURCE_GROUP> --template-file 07-enrichment-table-dcr.bicep --parameters workspaceName=<LOG_ANALYTICS_WORKSPACE_NAME> senderPrincipalId=<SENDER_PRINCIPAL_ID>`).
2. Emit one enrichment record per call with `04-app-enrichment.py` or `09-app-enrichment.cs`,
   keyed by the `apim-request-id` response header (which equals the diagnostic
   `CorrelationId`). The app id and cost center come from the app's own context and a
   governed map, never from anything the caller can type.
3. Left join the enrichment onto the platform rows on that key. If the enrichment write
   fails, you lose enrichment, never the meter.

## Step 5: guard the undocumented shape

Schedule `aoai-no-gateway/06-canary-schema-drift.kql` as a Log Analytics alert. It fires if
the identity or token field disappears, or if the `CorrelationId` join breaks. Pair it with a
synthetic call every few minutes so there is always a known-good row to check.

## Step 6 (optional): Power BI

If you want Power BI alongside the portal in this repo, follow
`aoai-no-gateway/08-powerbi-setup.md`: an M query that pushes the work into KQL, four
measures (never one blended number), and row-level plus object-level security. Remember that
report security protects the report, not the source; restrict workspace RBAC separately.

## Verification gates before production

1. Run `05-verify-sp-mi-caller.ps1` in your own tenant to settle what a managed identity or
   service principal writes to `callerObjectId`. This decides whether per-app is native.
2. Confirm the reasoning-token composition for each reasoning model in use.
3. Confirm which deployments are pay-as-you-go versus PTU, and exclude PTU from the
   per-caller dollar measure (PTU is billed by capacity-hour regardless of tokens).
4. Reconcile one day of the estimate to Cost Management at resource x deployment x day, and
   record the variance. Cost Management settles over hours to days — reconcile over a settled
   period, not same-day.
5. Complete the privacy or DPIA review, and lock workspace RBAC and retention.
6. Enable the canary and the synthetic call.

## Feed the portal

Once rows are flowing, the portal can consolidate this with Pattern B. See
`docs/04-portal.md`.
