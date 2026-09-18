# The portal

`portal/index.html` is a single self-contained page that shows both billing views and a
combined total on one screen. It has no external dependencies (no CDN scripts, styles, or
fonts) and it is live-only: it reads `portal/data.json` and renders "Not configured" until
you generate that file. It ships with no sample data on purpose, so nothing you see is ever
fabricated.

## The three views

- Azure OpenAI, no gateway: per-principal token usage and list-price cost from Pattern A.
- Claude, via gateway: per-user prompt and completion tokens and list-price cost from
  Pattern B.
- Combined total: cost, tokens, calls, and distinct principals across both.

Each view shows KPI cards, an estimated-cost-by-model bar chart, a per-principal table, and a
"token meters by model" table (input, output, cache-write, cache-read, thinking). The combined
total sits at the top so the headline number is the first thing you see. A persistent
honest-framing banner explains how to read the numbers: tokens are measured, dollars are a
list-price estimate, cache-write is a premium and cache-read a discount, and thinking/reasoning
tokens are already inside output (shown for transparency, never added to cost).

The meter table renders "—" for any meter a pattern does not carry, so a blank cell never reads
as a captured zero. Azure OpenAI shows input (= prompt − cached), output, and cache-read (the
automatic cached subset); cache-write (billed on GPT-5.6+) and per-user reasoning are not on this
query path, so they render "—". Claude shows input and output per user;
its cache-write (5m/1h) and cache-read columns populate only when the Claude source is the
app-side / non-streaming capture — on the streaming gateway path they stay "—" and cache
reconciles at the resource total.

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
