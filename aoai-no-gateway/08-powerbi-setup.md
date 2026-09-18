# Pattern A - Power BI setup (showback + reconciliation)

The reporting layer over the attributed data, for teams that want Power BI alongside
the lightweight HTML portal in this repo. Import to a daily grain; do not DirectQuery
per-call. Use the Analytics table plan on any custom table. Report on pseudonymized
identity; keep the raw oid restricted.

Prerequisites: the attribution logs from `02-attribution.kql` are flowing, and you
have Power BI Desktop plus read access to the Log Analytics workspace.

Placeholders to fill: `<SUBSCRIPTION_ID>`, `<RESOURCE_GROUP>`, and
`<LOG_ANALYTICS_WORKSPACE_NAME>` in the M query below.

## 1. Connect (M query)

Preferred: the Azure Data Explorer (Kusto) connector pointed at the Log Analytics proxy cluster.
In Power BI Desktop, Get Data -> Azure Data Explorer (Kusto), or paste this M and fill the placeholders.
You can also generate this from Log Analytics with "Export -> Export to Power BI (M query)".

```m
let
    ClusterUrl = "https://ade.loganalytics.io/subscriptions/<SUBSCRIPTION_ID>/resourcegroups/<RESOURCE_GROUP>/providers/microsoft.operationalinsights/workspaces/<LOG_ANALYTICS_WORKSPACE_NAME>",
    Database   = "<LOG_ANALYTICS_WORKSPACE_NAME>",
    // Push the heavy lifting (parse, filter the 2x row, join, aggregate) into KQL, per 02-attribution.kql.
    Query =
      "AzureDiagnostics
       | where ResourceProvider == 'MICROSOFT.COGNITIVESERVICES'
       | where Category == 'RequestResponse' and event_s == 'ShoeboxCallResult'
       | extend p = parse_json(properties_s)
       | extend callerOid = tostring(p.callerObjectId)
       | where isnotempty(callerOid)
       | project TimeGenerated, CorrelationId, callerOid,
                 promptTokens = tolong(p.promptTokens),
                 completionTokens = tolong(p.completionTokens),
                 model = tostring(p.modelName),
                 deployment = tostring(p.modelDeploymentName)
       | summarize promptTokens = sum(promptTokens), completionTokens = sum(completionTokens), calls = count()
                 by bin(TimeGenerated, 1d), callerOid, model, deployment",
    Source = AzureDataExplorer.Contents(ClusterUrl, Database, Query, [])
in
    Source
```

Bring three more tables the same way or as CSV/Cosmos:
- `RateCard` (from 03-pricing-table.sample.csv, effective-dated),
- `CostManagement` (a daily FOCUS/Cost Management export at resource x deployment x day, for reconciliation),
- `PrincipalMap` (oid -> pseudonym, cost center, effective-dated; keep this in a restricted workspace).

## 2. Model

- Star schema, daily grain. `Attribution` is the fact. `RateCard`, `PrincipalMap`, `Date` are dimensions.
- Join `Attribution[model]` to the effective-dated `RateCard` on model + date range.
- Replace `callerOid` in visuals with `PrincipalMap[Pseudonym]`. Do not surface the raw oid.

## 3. Measures (publish four, never one blended number)

```DAX
Observed Tokens =
    SUM ( Attribution[promptTokens] ) + SUM ( Attribution[completionTokens] )

// Best computed in KQL (02-attribution.kql Q3) and summed here. If done in DAX, join RateCard first.
List-Price Estimate (USD) =
    SUMX (
        Attribution,
        VAR billableInput = Attribution[promptTokens] - Attribution[cachedTokens]  // cached is a SUBSET of input
        RETURN
            DIVIDE ( billableInput * RELATED ( RateCard[input_per_1m] ), 1000000 )
          + DIVIDE ( Attribution[cachedTokens] * RELATED ( RateCard[cached_input_per_1m] ), 1000000 )
          + DIVIDE ( Attribution[completionTokens] * RELATED ( RateCard[output_per_1m] ), 1000000 )
    )

Allocated Cost (Tariff USD) =            // your internal tariff, if you chargeback that way (placeholder)
    [Observed Tokens] * 0                 // replace with an approved tariff table lookup

Billed Cost (USD) =                       // invoice truth, from Cost Management, at resource x deployment x day
    SUM ( CostManagement[billed_usd] )

Reconciliation Variance (USD) =           // keep as a NAMED residual; never smear onto individuals
    [List-Price Estimate (USD)] - [Billed Cost (USD)]

Attribution Coverage % =                  // health, not a bill
    VAR attributed = COUNTROWS ( Attribution )
    VAR total = CALCULATE ( COUNTROWS ( AllInferenceRows ) )   // total ShoeboxCallResult rows
    RETURN DIVIDE ( attributed, total )
```

Label the estimate measure in every visual as a list-price estimate. Exclude PTU deployments from the
per-caller dollar visuals (PTU is capacity-hours; report its utilization and allocate its fixed cost separately).

## 4. Row-level and object-level security

- RLS: a `Security` table maps user email to allowed `CostCenter`. Role filter:
  `PrincipalMap[CostCenter] IN CALCULATETABLE ( VALUES ( Security[CostCenter] ), Security[Email] = USERPRINCIPALNAME() )`.
- OLS: hide the raw `callerOid` column from all non-privileged roles; expose only the pseudonym.
- RLS/OLS protect the report, not the source. Restrict Log Analytics workspace RBAC separately.
- Apply small-cohort suppression so a team of one is not singled out.

## 5. Reconciliation view

One page at resource x deployment x day: List-Price Estimate vs Billed Cost vs Variance, plus Coverage %.
Finance reconciles here; the per-caller pages are showback, explicitly labeled as estimates.
