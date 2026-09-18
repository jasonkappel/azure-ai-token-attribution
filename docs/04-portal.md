# The portal

`portal/index.html` is a single self-contained page with a left navigation pane and four views.
It has no external dependencies (no CDN scripts, styles, or fonts) and it is live-only: it reads
`portal/data.json` and renders "Not configured" until you generate that file. It ships with no
sample data on purpose, so nothing you see is ever fabricated.

## The four views (left nav)

- **Overview**: KPIs (total est. spend, departments, applications, users), spend by department,
  by model, by user, by pipeline, a department → application → user table, and a token-meters
  table. This is the headline screen.
- **Azure OpenAI**: the same breakdown scoped to the no-gateway (Pattern A) pipeline.
- **Claude (gateway)**: the same breakdown scoped to the gateway (Pattern B) pipeline.
- **By user**: spend per human, with the departments and apps each user touched.

Every view has a **date-range** control (7d / 14d / 30d / All) and **drill-down**: click a
department or user anywhere and the whole portal filters to it, with removable chips that compose
(e.g. one department + one user). All aggregation is client-side, so filters recompute instantly.

A persistent honest-framing banner explains how to read the numbers: tokens are measured, dollars
are a list-price estimate, cache-write is a premium and cache-read a discount, and thinking /
reasoning tokens are already inside output (shown for transparency, never added to cost).

The token-meters table renders `n/a` when a meter does not exist for a pattern and `—` when it
exists but was not captured on this query path — so a blank cell never reads as a captured zero.
Azure OpenAI shows input (= prompt − cached), output, and cache-read; cache-write (billed on
GPT-5.6+) and per-user reasoning are not on the platform-log path, so they render `—`. Claude
shows input, output, and — when the source is the enrichment table or the app-side / non-streaming
capture — cache-write, cache-read, and thinking; on the streaming gateway path per-user cache
stays `—` and reconciles at the resource total.

## Where department / app / user come from

The portal prefers the **enrichment custom table** (`AiSpendEnrichment_CL`), which carries
department / app / user and every token meter per call. Create it with
`portal/enrichment-table-dcr.bicep` (schema and how it relates to the Pattern A cross-check table
are in `docs/07-data-model.md`). When that table is not wired, `query-helper.ps1` falls back to the
platform diagnostic log (Pattern A) and gateway LLM log (Pattern B) and attributes **per
principal** — department / app / user then read "(unattributed)" and the record's principal oid
stands in for the user. The sidebar's data-source note tells you which mode produced the current
view. A failed query shows a red banner (never a silent $0).


## What you supply

Copy `portal/config.sample.json` to `portal/config.json` and fill in three values:

```json
{
  "workspaceId": "<LOG_ANALYTICS_WORKSPACE_ID>",
  "timeRangeHours": 168,
  "rateCardCsv": "./rate-card.csv"
}
```

- `workspaceId`: the Log Analytics workspace GUID (customerId). Get it with
  `az monitor log-analytics workspace show --query customerId`.
- `timeRangeHours`: the lookback window for both queries, in hours. 168 is 7 days.
- `rateCardCsv`: path to your effective-dated rate card. It uses the same columns as
  `aoai-no-gateway/03-pricing-table.sample.csv`. Never commit real contract prices; this file
  and `data.json` are git-ignored.

## Generate the data

```
./portal/query-helper.ps1
```

It reads `config.json`, runs the Pattern A and Pattern B attribution queries against your
workspace with `az monitor log-analytics query`, prices each row with your rate card, and
writes `portal/data.json`. A pattern you have not wired up simply returns no rows, so you can
run the portal with one pattern or both. Then open `portal/index.html` and reload.

## A note on file:// and fetch

The page loads `data.json` with `fetch`. Some browsers block `fetch` over the `file://`
protocol, so if you double-click `index.html` and still see "Not configured" after generating
`data.json`, serve the folder over http instead:

```
cd portal
python -m http.server 8080
```

Then open `http://localhost:8080/`.

## What the portal is not

It is showback, not the invoice. Every dollar figure is a list-price estimate reconciled to
Cost Management. Azure OpenAI figures are per authenticated caller, so a shared identity
collapses to one principal. Claude figures are prompt and completion only; per-user cache is
not captured at the gateway on streaming and reconciles at the resource total. The page states
these caveats inline so no one mistakes an estimate for a bill.
