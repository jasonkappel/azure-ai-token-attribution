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
