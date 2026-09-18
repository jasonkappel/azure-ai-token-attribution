# Pilot decision brief and pre-pilot gate

Read this **before** you run any setup script. The setup guides create employee-identifying
telemetry and (for Pattern B) billable infrastructure. This page is two things: a one-page brief a
**sponsor** approves, and a **blocking checklist** an **implementer** must clear before enabling
any live logging. Do not skip to the quickstarts.

---

## Part 1 — Sponsor decision brief (one page)

**What this enables.** Cost *visibility* — who (person or app) used how many AI tokens, and a
list-price *estimate* of what it cost — across two Azure patterns, surfaced in one portal and
reconcilable to Cost Management.

**What this is NOT.** It is **showback with a named residual, not an invoice-exact chargeback**.
Dollars are a list-price estimate reconciled to the Marketplace/Cost Management total, with the gap
reported as a residual — not a per-person bill. It is **not a security certification**, and the
per-user quota (Pattern B) is a **bounded guardrail with overshoot**, not a hard spend limit.

**What it costs the business.**
- It **logs employee identity** (`callerObjectId` / `x-caller-oid`) — this is workforce-monitoring
  telemetry with privacy/DPIA and, in some jurisdictions, notice/consent and works-council
  obligations.
- The observability itself has a meter: **Log Analytics ingestion/retention** (both patterns) and,
  for Pattern B, a **fixed monthly APIM v2 cost**. See `docs/00-prerequisites.md §5`.

**What has been demonstrated vs what has not.**

| Demonstrated | Not yet proven / out of scope for this toolkit |
|---|---|
| Per-principal attribution + list-price estimate from native logs (Pattern A), live | Invoice-exact chargeback (needs settled-period reconciliation in your tenant) |
| Per-user attribution + token quota through the gateway (Pattern B), live | Security controls (least-privilege, app-only-not-attributed, bypass-denied) — **not covered by the automated acceptance test** |
| Full token-meter fidelity incl. cache/thinking (app-side / enrichment) | Per-user **cache** on streaming Claude (reconciles at resource total only) |
| Offline accounting logic + a live round-trip acceptance test | Durability of some log fields — several are **pilot-observed, not contracted** by Microsoft |

**Choose the pattern.**

| If you need… | Pick | It costs |
|---|---|---|
| Showback on apps that authenticate with Entra; cheapest path | **Pattern A** (no gateway) | Log Analytics only |
| Enforcement (per-user quota) and/or per-user attribution through a client you cannot instrument (e.g. Claude Code) | **Pattern B** (APIM gateway) | Log Analytics + APIM v2 + hardening |

**The approval request.** Approve a **time-bounded, resource-scoped pilot** with: a named pattern,
a spending cap, accountable **FinOps / security / platform** owners, explicit **success and stop
criteria**, and a named **teardown owner**. Approving this pilot approves *learning* — it does not
approve production chargeback, workforce surveillance, or production enforcement. Those require a
separate decision after the pilot's reconciliation and security gates pass.

---

## Part 2 — Pre-pilot gate (implementer must clear ALL before enabling live logging)

Do **not** run `01-enable-diagnostics` (either pattern) or any `-Live` acceptance run until every
box is checked. The first diagnostic setting you enable starts writing employee-identifying rows.

- [ ] **Pattern chosen** and its true cost accepted (A = Log Analytics; B = + APIM v2). See the table above.
- [ ] **Identities and meters catalogued** — you can name exactly what gets logged (`callerObjectId` /
      `x-caller-oid`, token counts) and where it lands (which workspace, which table).
- [ ] **Employee-data approval obtained BEFORE any logging** — privacy review / DPIA signed, and any
      required notice / consent / works-council step done. (This is a gate on the *pilot*, not just production.)
- [ ] **Data flow + region approved** — workspace is in an approved region for residency; retention set to policy.
- [ ] **Least privilege configured** — the per-task roles in `docs/00-prerequisites.md §2` are used;
      the only elevated grant is the one role-assignment step (Pattern B).
- [ ] **RBAC locked** — Log Analytics Reader on the workspace is restricted to a short, reviewed list;
      no body logging; `Authorization` / `x-api-key` deny-listed on every logger.
- [ ] **Offline acceptance is green** — `./acceptance/run-acceptance.ps1` passes on your machine.
- [ ] **Spending cap + teardown owner named** — you know what you are creating (resource group, APIM
      name, app id, DCE/DCR, custom table) so teardown (`docs/05-operations-and-gotchas.md`) is a checklist.

**Expected evidence the pilot is working** (so "green" means something):
- Pattern A: `02-attribution.kql` returns **one** attributed row per call (not two), with your callers' oids.
- Pattern B: `08-sample-agent.ps1` shows the quota header decrementing; `09-attribution.kql` attributes per user.
- Acceptance `-Live`: identity provenance + token-fidelity + dedup + coverage all PASS against your deployment.

**Stop / rollback criteria.** If acceptance fails on identity or reconciliation, if log volume/cost
exceeds the cap, or if a pilot-observed field changes (the canary fires): **stop, do not chargeback**,
and run the teardown checklist to remove diagnostics, the enrichment pipeline, APIM, and the app
registration, then purge/age out the workspace data per policy.

Once the gate is clear, proceed to `docs/02-setup-aoai-no-gateway.md` or
`docs/03-setup-claude-gateway.md`.
