# Setup: Claude via an APIM AI gateway (Pattern B)

This gets you per-user attribution and a per-user token quota for Claude Code calling a
Foundry-hosted Claude model through an API Management gateway. The gateway validates the
user's own Entra token, so you can attribute and throttle per person even though Claude Code
is a third-party CLI you do not control.

## What you need first

- A Foundry resource with Claude deployed (for example Sonnet, Opus, Haiku). Billing is Azure
  Marketplace token-metered pay-as-you-go.
- An APIM v2 tier. The Anthropic Messages `llm-*` policies understand the Anthropic schema
  only on v2 (Basic v2, Standard v2, or Premium v2).
- Azure CLI signed in with rights to deploy ARM, create an app registration, wire APIM, and
  assign a data-plane role on the Foundry resource.
- The same governance decision as Pattern A, plus more sensitivity: coding-tool usage per
  developer is worker monitoring. Complete a privacy review or DPIA first.

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
oid, model, usage object, the `x-tokens-consumed` and `x-remaining-tokens` quota headers, and
the `apim-request-id`.

## Step 6: report

Run `claude-gateway/09-attribution.kql` in the workspace. It joins the native LLM token log to
the caller oid and gives per-user prompt and completion tokens, a list-price estimate, and the
resource-level reconciliation. Per-user cache is not captured; that is by design on streaming.

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
