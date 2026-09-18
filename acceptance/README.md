# Acceptance test

`run-acceptance.ps1` is the evidence a FinOps or security reviewer asks for: proof that the
toolkit's numbers are correct end to end and fail loudly when they are not. It is not a demo — it
makes assertions and returns a non-zero exit code if any fail, so you can wire it into CI.

It has two layers.

## Offline layer (default, no Azure, ~1 second)

Proves the accounting **logic** is right, against a fixed test rate card
(`test-rate-card.csv`, round numbers) so every expected dollar is hand-verifiable and never drifts
when you edit your real rates:

- **The two cost algebras.** Azure OpenAI is *inclusive* (billable input = prompt − cached);
  Claude is *exclusive/additive* (total input = input + cache-write + cache-read).
- **Cache tiers and discounts.** 5-minute write (~1.25×), 1-hour write (~2×), cache read (~0.1×),
  and a scalar-write fallback so a captured write is never billed at $0.
- **Thinking is billed as output — never added, never subtracted.** A "subtract thinking" bug would
  zero out almost all of an extended-thinking call; the suite proves we do not.
- **Integrity gates fire.** `thinking ≤ output`, AOAI `cached ≤ prompt`, and Claude
  `ephemeral_5m + ephemeral_1h == cache_creation` — each violation is caught, not silently billed.
- **Dedup, coverage, reconciliation.** A double-logged call collapses to one; coverage is a
  visible percentage; the estimate-vs-resource gap is a named residual.
- **Unknown price is UNPRICED (null), never $0.**

Run it:

```
./acceptance/run-acceptance.ps1
```

## Live layer (opt-in, needs a wired Pattern A deployment)

Proves the **round trip**: identity → captured usage → ingestion → priced result, plus a
least-privilege preflight. It signs in as you, fires a couple of real Azure OpenAI calls, waits for
the diagnostic log, and asserts:

- **Identity provenance** — the platform log's `callerObjectId` equals *your* Entra object id (not
  the app, not a managed identity).
- **Meter fidelity** — the tokens in the platform log equal the tokens in the model's `usage`
  object.
- **Dedup** — each call produces exactly one attributed row (the `RequestResponse` category emits
  two rows per call; the toolkit filters to one).
- **Coverage** — captured / fired = 100% for a clean run; a miss shows up as a lower percentage.
- **RBAC preflight** — the workspace is actually queryable (Log Analytics Reader on the workspace,
  not just Reader on the resource).
- **Priced result** — the captured calls are priced with your **production** rate card
  (`aoai-no-gateway/03-pricing-table.sample.csv`). If the deployment has no rate row it reports
  UNPRICED rather than inventing a number.
- **Reconciliation** — reported, not gated, because Cost Management lags hours to days. Pass
  `-ResourceTotalUsd <n>` once the Marketplace meter has settled to compute the residual.

Run it:

```
./acceptance/run-acceptance.ps1 -Live `
  -WorkspaceId <LOG_ANALYTICS_WORKSPACE_GUID> `
  -FoundryEndpoint https://<FOUNDRY_RESOURCE_NAME>.cognitiveservices.azure.com `
  -Deployment <CHAT_DEPLOYMENT_NAME> `
  [-CallCount 2] [-ResourceTotalUsd 0]
```

Prerequisites for the live layer: `az login` as a user who can call the Foundry deployment and read
the workspace, and the Pattern A diagnostic settings enabled (`aoai-no-gateway/01-enable-diagnostics.azcli`).

## Why the shared module matters

Both the acceptance test and the portal's `query-helper.ps1` import the same cost model,
`lib/AiBilling.Metering.psm1`. The test therefore exercises the **exact** math the portal ships —
not a copy that could drift. If you change the pricing logic, change it in one place and this suite
guards it.

## Exit code

`0` = every assertion passed. `1` = at least one failed. Suitable for CI.

## What it does NOT prove (read before you screenshot a green run)

A green run is scoped evidence, not blanket validation. The final banner states this explicitly:

- **Offline-only means logic, not your deployment.** `OFFLINE LOGIC: PASS` proves the accounting
  math; it says nothing about your Azure wiring. Only a `-Live` run with `PATTERN A LIVE: PASS`
  exercises your deployment.
- **Pattern B (Claude gateway) is not tested here.** It needs a wired gateway; validate it per
  `docs/03-setup-claude-gateway.md`. The banner marks it `NOT TESTED`.
- **Security controls are not tested.** The suite proves the caller's oid is *logged*; it does not
  prove an app-only / managed-identity caller is correctly **not** attributed to a human, that a
  shared-identity call is flagged, or that an unauthorized caller/reader is denied. Run those with
  documented **minimal** roles (not Owner) before a security sign-off. The banner marks this
  `NOT TESTED`.
- **The live path leans on pilot-observed fields.** `callerObjectId`, the `properties_s` token
  counts, and `event_s == 'ShoeboxCallResult'` are observed, not documented/contracted by
  Microsoft. If they change, the live asserts fail loudly (by design) — treat a failure as "verify
  the field", not "the bill is wrong". Pin the probe to a **non-streaming, non-reasoning, no-tools**
  deployment, or the token-equality assert can legitimately fail on reasoning tokens.
- **Reconciliation is `PENDING` until you supply a settled total.** Cost Management lags hours to
  days. Pass `-ResourceTotalUsd` to report a residual, and `-ReconcileTolerance` to *gate* it — but
  only against a total scoped to **these** calls, never an unrelated resource-day sum. "Reported"
  is fine during lag; a permanent financial sign-off needs the gated form over a settled period.

