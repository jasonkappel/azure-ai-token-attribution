# Operations and gotchas: what else you should be thinking about

The setup guides get you a working attribution feed. This page is the "what am I not thinking
about" list — the things that decide whether it survives contact with production, a bank's
security review, and next quarter's Azure change. Read it before you put a number in front of
finance or turn logging on tenant-wide.

## Data governance (do this before production, not after)

- **This is worker-monitoring telemetry.** `callerObjectId` (Pattern A) and `x-caller-oid`
  (Pattern B) identify employees, and coding-tool usage is more sensitive still. Complete a
  privacy review or DPIA before production. In many jurisdictions employee monitoring has
  notice/consent obligations — involve privacy and, where relevant, works councils early.
- **Restrict who can query.** Log Analytics Reader on the workspace is the query grant; keep the
  list short and reviewed. Reader on the model resource is not enough (by design) — do not widen
  it to "fix" access.
- **Pseudonymize in the reporting layer.** Show a stable surrogate, not the raw oid, and keep the
  oid→person mapping in a restricted dimension. The portal truncates the oid for display, but
  that is cosmetic — pseudonymize upstream for a governed deployment.
- **Small-cohort suppression.** A "team" of one is an individual. Suppress or roll up cohorts
  below a threshold so a chart cannot single someone out.
- **Retention and residency are deliberate choices.** Set workspace retention to your policy (not
  the default), and put the workspace in an approved region. Longer retention = more cost and
  more standing personal data; pick on purpose.
- **Never log prompt or completion bodies**, and deny-list the `Authorization` and `x-api-key`
  headers on every logger so a token is never captured in diagnostics.

## Sensitivity labels and outputs

If the calls carry Microsoft Information Protection (MIP) labels, the attribution *metadata*
(who/how many tokens) is not the content, but any export you build (a Power BI dataset, a CSV,
a shared portal `data.json`) can still expose identity and usage patterns. Treat exports as
governed data: `portal/data.json` holds live identity data and is git-ignored on purpose — never
commit it, and be deliberate about who can open the served portal.

## Cost of the observability itself

Turning on the logging that lets you attribute spend *costs* (Log Analytics ingestion). Before a
tenant-wide rollout, estimate log volume from a pilot resource, and revisit:

- which diagnostic categories you actually need (you need `RequestResponse` +
  `AzureOpenAIRequestUsage` for Pattern A, `GatewayLlmLogs` + the API diagnostic for Pattern B —
  not everything),
- retention length, and
- for very high volume, the Log Analytics table plan (Analytics vs Basic) — but note this toolkit
  JOINs and exports, which needs the Analytics plan.

## Pricing accuracy (the numbers finance will challenge)

- **List price is an estimate, not the invoice.** Reconcile to Cost Management / the Marketplace
  meter and carry the gap as a *named residual* owned by the platform team — never smear it across
  individuals. Publish four measures, never one blend: observed tokens, list-price estimate,
  allocated (tariff) cost, and billed cost.
- **Reconciliation lags.** Cost Management and Marketplace meters settle over **hours to days**.
  Do not gate a chargeback on a same-day comparison; reconcile over a settled period.
- **Exclude PTU / provisioned capacity from the per-token dollar.** Provisioned throughput is
  billed by capacity-hour regardless of tokens; pricing its tokens at PAYG list is wrong. Tag PTU
  deployments and report their utilization separately.
- **Rate cards are effective-dated and owned.** Keep the authoritative, negotiated card in a
  governed store — never commit contract prices to a repo. The shipped CSV is illustrative
  public-list placeholders. When a model's price changes, add a new effective-dated row; do not
  overwrite history, or past months reprice.
- **Two token algebras.** Azure OpenAI `prompt_tokens` *includes* cached (billable = prompt −
  cached); Claude `input_tokens` is already uncached (total input = input + cache-write +
  cache-read). Cache-write is a premium (5m ≈ 1.25×, 1h ≈ 2×), cache-read a discount; thinking /
  reasoning tokens are inside output and are never a separate charge. `docs/01-how-it-works.md`
  and `lib/AiBilling.Metering.psm1` are the source of truth, and `acceptance/run-acceptance.ps1`
  guards them.

## Undocumented fields will change — plan for it

Some fields this toolkit relies on are **pilot-observed, not contracted by Microsoft**:
`callerObjectId`, the `properties_s` token counts, and `event_s == 'ShoeboxCallResult'` in the
`RequestResponse` log; and the `CorrelationId == apim-request-id` join. They work today and are
load-bearing, but Microsoft can rename them or move the data to a dedicated/resource-specific
table without notice.

- **Run the canary** (`aoai-no-gateway/06-canary-schema-drift.kql`) on a schedule with a synthetic
  call, so a change surfaces as a visible **coverage drop**, not a silently wrong bill.
- Treat a live acceptance failure on these fields as "verify the field", not "spend is zero".

## Networking, scale, and enforcement (Pattern B)

- **Put APIM on a private/internal network for production.** A gateway only enforces if it is on a
  mandatory path — block direct calls to Foundry and to public Anthropic endpoints, or users
  bypass the quota and the attribution.
- **The quota is a guardrail with overshoot.** `llm-token-limit` estimates for streaming and can
  overrun the cap; it is a control, not a hard billing boundary. Measure the overshoot.
- **APIM v2 is required** because Anthropic Messages API support in APIM is v2-tier-only (the
  `llm-*` policies themselves run on all tiers); the CLI rejects the v2 SKU names, so the ARM
  template provisions `Basicv2`. Scale units cost money — size for real load.
- **A shared managed identity collapses per-user.** If apps call the gateway (or the model) as one
  MI, everyone becomes one principal. Per-user needs the user's own token (Pattern B) or the
  app-side enrichment join (Pattern A).

## Streaming and cache fidelity (Pattern B)

- Per-user **cache** is not captured at the gateway on streaming — it reconciles at the resource
  total. Full per-call meters (cache-write 5m/1h, cache-read, thinking) come from the app-side /
  non-streaming capture or the enrichment table, not the streaming gateway log. The portal shows
  "—" for meters not on the current path — that is expected, not a defect.
- If you build an ingestion adapter for the app-side capture, **do not UNION** it with the gateway
  log (both carry prompt+completion → double-count). Pick one source of record per call; if you
  merge, replace by `apim-request-id` and tag `usage_source`.

## Enrichment table (the dept/app/user view)

- The portal prefers the enrichment custom table (`AiSpendEnrichment_CL`) for department / app /
  user and all meters; without it, it falls back to per-principal from the platform/gateway logs.
- The **app supplies** department/app/cost-center from its own governed context — never from
  anything the caller can type. A lost enrichment write must reduce **coverage** visibly, never
  silently lower someone's charge.
- If you evolve the table schema, keep the DCR stream in lockstep, version it, and re-run the
  acceptance/canary. Adding columns is additive; the immutable DCR id is unchanged.

## Security review checklist (hand this to the reviewer)

- [ ] Keys off on the model resource (`disableLocalAuth=true`); callers use Entra tokens.
- [ ] Workspace RBAC restricted; retention and region set to policy; oid pseudonymized in reporting.
- [ ] No body logging; `Authorization` / `x-api-key` deny-listed on every logger.
- [ ] (B) APIM on a private/internal network; direct-to-Foundry and public-Anthropic bypass both fail.
- [ ] (B) Gateway rejects app-only tokens (no `scp`); backend receives only the MI token; audience `https://ai.azure.com`.
- [ ] Least-privilege roles used for each task (not blanket Owner); the role-assignment step is the only elevated one.
- [ ] Privacy review / DPIA complete and signed.
- [ ] Canary + synthetic call scheduled; a field change alerts.

## Teardown (stop the meters)

When you decommission a pilot, remove what you stood up so it stops billing and stops holding
personal data:

- **Delete the diagnostic settings** on the model resource (and APIM), or the logs keep flowing
  and ingesting.
- **Delete the Log Analytics custom table / DCR / DCE** if you created the enrichment pipeline.
- **Delete the APIM instance** (Pattern B) — this is the main standing cost.
- **Delete the Entra app registration** (Pattern B) and any role assignments you created.
- **Purge or age out** the workspace data per your retention/records policy — remember it holds
  employee-identifying telemetry.

Track exactly what you created (resource group, APIM name, app id, DCR/DCE, custom table) so
teardown is a checklist, not an archaeology dig.
