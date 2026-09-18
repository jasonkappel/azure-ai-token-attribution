# Setup: Claude via an APIM AI gateway (Pattern B)

This gets you per-user attribution and a per-user token quota for Claude Code calling a
Foundry-hosted Claude model through an API Management gateway. The gateway validates the
user's own Entra token, so you can attribute and throttle per person even though Claude Code
is a third-party CLI you do not control.

## Azure services you will use

| Service | Why | Notes |
|---|---|---|
| Foundry resource with Claude deployed | The model behind the gateway | Billing is Azure Marketplace token-metered pay-as-you-go |
| API Management, v2 tier (`Microsoft.ApiManagement`) | The gateway that validates, strips, stamps, and throttles | Must be v2 (Basic v2 / Standard v2 / Premium v2) because **Anthropic Messages API support in APIM is v2-tier-only** — the `llm-*` policies run on all tiers, but the Anthropic schema needs v2. Put it on a private or internal network for production |
| Entra ID app registration | The audience the gateway validates tokens against | Created without admin consent (pre-authorizes the Azure CLI client) |
| Log Analytics workspace | Holds the gateway LLM log and the identity row | The attribution source of record |
| Azure Monitor (diagnostic settings + APIM logger) | Captures `GatewayLlmLogs` + the `x-caller-oid` header | Configured by `05-enable-diagnostics.ps1` |
| Azure Cost Management | Reconciles to the Marketplace meter total | Read access is enough |

## Permissions you need

| Task | Role | Scope |
|---|---|---|
| Deploy the APIM v2 ARM template (01) | Contributor | The resource group |
| Create the gateway app registration (02) | Application Developer (create app) | Entra tenant |
| Assign users to the `Claude.User` role (02) | Owner of the new service principal, or Cloud Application Administrator | The app / SP |
| Wire the API, backend, and policy (03) | API Management Service Contributor | The APIM instance |
| Grant the APIM managed identity the Foundry role (03) | Owner or User Access Administrator (or RBAC Administrator) | The Foundry resource |
| Enable gateway diagnostics (05) | API Management Service Contributor and Monitoring Contributor | APIM + the workspace |
| Run the attribution query (09) | Log Analytics Reader | The workspace |
| Call the gateway (developer) | Holds the `Claude.User` app role and can `az login` | n/a |
| Reconcile to the Marketplace meter | Cost Management Reader | The subscription or billing scope |

As in Pattern A, running the KQL needs **Log Analytics Reader on the workspace**, not just
Reader on APIM. The backend-role grant in step 3 is the one that trips people up: assigning a
role to the APIM managed identity requires Owner or User Access Administrator on the Foundry
resource, which is a higher bar than the API Management Service Contributor role that covers
the rest of the wiring.

## Before you begin

Read `docs/00-prerequisites.md` first. Two things trip people up here specifically:

1. **The Claude model must already be deployed.** Anthropic Claude models in Foundry are Azure
   Marketplace offerings — someone with Marketplace purchase rights has to enable the offer,
   accept its terms, and deploy `claude-opus-*` / `claude-haiku-*` before the gateway has
   anything to sit in front of. Billing is token-metered pay-as-you-go through Marketplace.
2. **Silent auth must actually work in your tenant.** The client helper mints a token with no
   prompt; if Conditional Access forces interactive MFA on that flow, or self-service app
   registration is blocked, you need an admin's help — confirm that before step 2, not at step 5.

## One decision to make first

> **⛔ Clear the pilot gate first.** Do not run Step 1 until you have worked through
> `docs/06-pilot-decision-and-gate.md`. This pattern logs `x-caller-oid` (per-developer coding
> intensity) and stands up billable APIM — both need sponsor approval, privacy/DPIA sign-off, and a
> spending cap **before** you begin.

The oid on every attribution record is per-developer coding intensity, which is more
sensitive than generic model use. Treat it as worker monitoring: complete a privacy review or
DPIA before production, and lock Log Analytics RBAC and retention.

The scripts are numbered in deployment order. Run them in sequence.

## Step 1: provision APIM v2 (ARM, not the CLI SKU)

```
az deployment group create -g <RESOURCE_GROUP> \
  --template-file claude-gateway/01-apim-basicv2.arm.json \
  --parameters serviceName=<APIM_NAME> publisherEmail=<ADMIN_EMAIL> location=<REGION>
```

Why ARM: the `az apim create` command does not accept the v2 SKU names, so this template uses
sku name `Basicv2` at apiVersion `2023-09-01-preview` with a system-assigned identity. Note
the `principalId` output; that managed identity is how the gateway authenticates to Foundry.
APIM takes a while to provision.

## Step 2: create the gateway app registration (no admin consent)

```
./claude-gateway/02-gateway-app-registration.ps1
```

This creates the Entra app the gateway validates tokens against, without needing tenant admin
consent. It works by pre-authorizing the Azure CLI public client for the app's
`user_impersonation` scope, so a developer who runs
`az account get-access-token --scope api://<GATEWAY_APP_ID>/.default` gets a token with no
consent prompt. The app also exposes a `Claude.User` role; only assigned users can call the
gateway. The script prints `<GATEWAY_APP_ID>` and the URI form. Keep both.

## Step 3: wire the backend and apply the policy

```
./claude-gateway/03-wire-backend.ps1 \
  -SubscriptionId <SUBSCRIPTION_ID> -ResourceGroup <RESOURCE_GROUP> \
  -ApimName <APIM_NAME> -FoundryResourceName <FOUNDRY_RESOURCE_NAME> \
  -ApimPrincipalId <APIM_MI_PRINCIPAL_ID>
```

Before you run it, open `claude-gateway/04-apim-policy.xml` and fill `<TENANT_ID>` and
`<GATEWAY_APP_ID>` (the app id appears in `<audiences>` twice on purpose, as the bare GUID and
as `api://<GUID>`, because different token-mint paths stamp the audience either way).

The script creates the API (`claude-anthropic`, path `anthropic`, `subscriptionRequired=false`),
a named backend `foundry-claude`, the `POST /v1/messages` operation, grants the APIM managed
identity the Foundry data-plane role, and applies the policy. One gotcha it handles for you:
`az rest` fails if the request body has a UTF-8 byte-order mark, so the policy is written
BOM-less.

The policy authenticates to the backend with audience `https://ai.azure.com`, not
`cognitiveservices.azure.com` (that is Azure OpenAI only). It also injects the
`anthropic-version` header if the client did not send one, which Foundry Claude requires.

## Step 4: enable gateway diagnostics

```
./claude-gateway/05-enable-diagnostics.ps1 \
  -SubscriptionId <SUBSCRIPTION_ID> -ResourceGroup <RESOURCE_GROUP> \
  -ApimName <APIM_NAME> -WorkspaceName <LOG_ANALYTICS_WORKSPACE_NAME>
```

This sends `GatewayLlmLogs` (per-request prompt and completion tokens, streaming-safe) and
`GatewayLogs` to the workspace, and configures an API diagnostic at 100% sampling that
captures the `x-caller-oid` request header the policy stamps. Both land in `AzureDiagnostics`
and join by `CorrelationId`. Do not enable body logging.

## Step 5: configure the client and prove the path

Fill `claude-gateway/06-claude-code-settings.json` (`<APIM_NAME>`, `<GATEWAY_APP_ID>`,
`<TENANT_ID>`, and the three deployment names) and deploy `07-apikeyhelper.sh` as the
apiKeyHelper. Deliver these via managed settings so `ANTHROPIC_BASE_URL` cannot be repointed
at a public endpoint.

Before wiring the real CLI, prove the gateway end to end with the sample agent:

```
./claude-gateway/08-sample-agent.ps1 \
  -ApimName <APIM_NAME> -GatewayAppId <GATEWAY_APP_ID> -TenantId <TENANT_ID> \
  -Deployments <CLAUDE_HAIKU_DEPLOYMENT>,<CLAUDE_SONNET_DEPLOYMENT>
```

It mints one token and loops prompts across deployments using a single pooled `HttpClient`.
That detail matters: a loop of `Invoke-WebRequest` calls opens a fresh socket each time and a
burst exhausts ephemeral ports, so the batch fails partway. It records per call the caller
oid, model, the full usage object — input (already uncached), output, cache-write with the
ephemeral 5m/1h tiers, cache-read, and thinking (a subset of output) — plus the raw usage JSON,
the `x-tokens-consumed` and `x-remaining-tokens` quota headers, and the `apim-request-id`.
Because these are non-streaming calls, the single response carries the whole usage object; a
streamed response splits usage across `message_start` (input + cache) and `message_delta`
(output), so a streaming client must merge the two rather than take the last usage object.

## Step 6: report

Run `claude-gateway/09-attribution.kql` in the workspace. It joins the native LLM token log to
the caller oid and gives per-user prompt and completion tokens, a list-price estimate, and the
resource-level reconciliation. Per-user cache is not captured; that is by design on streaming.
Reconciliation lags — Cost Management / Marketplace meters settle over hours to days, so compare
over a settled period, not same-day.

### Expected results by capture path (so you do not think the toolkit is broken)

The full meters populate only on the path that actually carries them. This is expected behavior,
not a defect:

| Capture path | Input / output per user | Cache-write (5m/1h) · cache-read · thinking |
|---|---|---|
| Streaming gateway log (`09-attribution.kql`, the shipped default) | Yes | **Not captured** — portal shows "—"; cache reconciles at the resource total |
| App-side / non-streaming capture (`08-sample-agent.ps1`) | Yes | Yes — full per-call meters in the response `usage` object |

A cloned deployment that wires only the streaming gateway path **will** see every Claude
cache/thinking cell as "—". That is correct. To populate them you must add an ingestion adapter
for the app-side capture (not shipped as a portal source — the sample agent prints to the
console, it does not write `data.json`).

> **Do NOT UNION the two sources.** If you ingest the app-side capture as the Claude source, it
> already contains prompt+completion, so concatenating it with the gateway log double-counts
> prompt/completion while cache appears once. Pick ONE source of record per call and, if you
> ever merge, dedupe on `apim-request-id` (replace, never union) and tag each row with a
> `usage_source` so reconciliation can tell app-reported from gateway-metered.

## Verification gates before production

Prove these in a pilot, do not assume them:

1. Silent auth on a Conditional-Access-managed workstation: the helper mints a token with no
   prompt, correct tenant and audience, and refreshes before expiry across a long session.
2. Streaming token capture: a real streamed call produces an `ApiManagementGatewayLlmLog`
   record with non-zero tokens joined to `x-caller-oid`, and the quota decrements.
3. Credential hygiene: the backend never receives `x-api-key` or the user `Authorization`, and
   traces and loggers do not contain the token.
4. App-only rejection: a service-principal token, which carries no `scp`, is refused.
5. Concurrency and retries: parallel and retried calls are each recorded, and quota overshoot
   is measured and documented.
6. Reconciliation: a week of the summed per-user estimate against the Marketplace meter, with
   the cache-dominated residual recorded.
7. Bypass: from a developer box, a direct call to Foundry and to a public Anthropic endpoint
   both fail.
8. Platform: the APIM tier is v2, APIM is on a private or internal network,
   `subscriptionRequired=false`, and the managed identity holds the Foundry role with audience
   `https://ai.azure.com`.
9. Privacy: DPIA complete, Log Analytics RBAC and retention locked, oid pseudonymized at emit.

## Feed the portal

Once rows are flowing, the portal consolidates this with Pattern A. See `docs/04-portal.md`.
