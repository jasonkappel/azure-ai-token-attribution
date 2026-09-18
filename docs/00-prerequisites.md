# Prerequisites: what you need before you start

Read this first. It covers the tools on your machine, the Azure and Entra rights you need to
even begin, the one-time model enablement people forget, the order to do things in, and what the
tooling itself costs. The per-pattern setup guides (`02-...`, `03-...`) assume everything here is
already true.

## 1. Your workstation

| Tool | Why | Notes |
|---|---|---|
| **Azure CLI** (`az`), current | Every script and the portal's query-helper call `az` | `az login` first. The Log Analytics **query** command is in the `log-analytics` **extension**: the CLI usually auto-installs it on first use, but on locked-down / air-gapped workstations where dynamic install is disabled you must run `az extension add -n log-analytics` explicitly. Run `az version` and update if it is old. |
| **PowerShell 7+** (`pwsh`) | The `.ps1` scripts, the shared module, and the acceptance test | The scripts are written to also parse under Windows PowerShell 5.1, but **use 7+** — it is cross-platform and the tested target. |
| **Python 3** | Only to *serve* the portal locally (`python -m http.server`) | The portal is a static file; Python is just a convenient local web server. Any static server works. |
| A modern **browser** | To view the portal | The portal uses `fetch()`, which some browsers block over `file://` — serve over `http://` (see `docs/04-portal.md`). |

No Node, no build step, no framework. The portal is one self-contained HTML file.

## 2. Azure and Entra rights to begin

You do not need to be a global admin, but someone in the project needs each of these. The
per-pattern guides break the roles down by task; this is the "can we even start" summary.

| You must be able to… | Which pattern | Typical role |
|---|---|---|
| Create/So configure diagnostic settings on the model resource | A and B | Monitoring Contributor + Cognitive Services Contributor on the resource |
| Query a Log Analytics workspace | A and B | **Log Analytics Reader on the workspace** (not just Reader on the resource — the single most-forgotten grant) |
| Create an Entra **app registration** | B only | Application Developer in the tenant (or ask someone who is) |
| Assign an Azure **role to a managed identity** | B only | Owner or User Access Administrator on the Foundry resource (or the least-privilege Role Based Access Control Administrator) |
| Read **Cost Management** to reconcile | A and B | Cost Management Reader on the subscription/billing scope |

If your tenant blocks self-service app registration, or Conditional Access blocks silent
service-principal / device-code token acquisition, Pattern B needs an admin's help — find that
out *before* you start, not at step 3. (Pattern B's client helper mints a token silently; a CA
policy that forces interactive MFA on that flow will break it on managed workstations.)

## 3. One-time enablement people forget

- **Foundry / Azure OpenAI model access (both patterns).** The model deployment must exist and
  the callers must hold the data-plane role (**Cognitive Services OpenAI User**, or the Foundry
  equivalent **Foundry User**) on it. Attribution needs Entra auth, so turn **keys off**
  (`disableLocalAuth=true`) — a shared-key call carries no Entra token, so there is no principal to
  log. Note: disabling local auth can take up to several hours to fully propagate — plan for it.
- **Claude / Anthropic models in Foundry (Pattern B).** These are **Azure Marketplace**
  offerings. Before you can deploy `claude-opus-*` / `claude-haiku-*`, someone with Marketplace
  purchase rights must enable the offer and accept its terms in the Foundry portal, then deploy
  the model. Billing is token-metered pay-as-you-go through Marketplace. If the model is not
  deployed, Pattern B has nothing to sit in front of.
- **The gateway data-plane role (Pattern B).** The APIM managed identity needs the **Foundry
  User** role (formerly "Azure AI User") on the Foundry resource, with token audience
  `https://ai.azure.com`. This is the grant that requires Owner / User Access Administrator.

## 4. The order to do things in

1. **Run the acceptance test offline first** — `./acceptance/run-acceptance.ps1`. It needs no
   Azure and proves the accounting logic is sound on your machine in ~1 second. Start green.
2. **Pick a pattern.** Pattern A (no gateway) is the cheap showback path; Pattern B adds a
   gateway for enforcement and per-user attribution through a client you cannot instrument. Most
   people start with A. See the comparison in `README.md`.
3. **Clear the pilot gate.** Work through `docs/06-pilot-decision-and-gate.md` — the sponsor
   decision brief and the blocking pre-pilot checklist. **Employee-data approval, least privilege,
   a spending cap, and a teardown owner must be in place before you enable any live logging.**
4. **Follow the pattern's setup guide** (`docs/02-...` or `docs/03-...`), in numbered order.
5. **Wire the portal** (`docs/04-portal.md`) and, if you want it, Power BI
   (`aoai-no-gateway/08-powerbi-setup.md`).
6. **Read `docs/05-operations-and-gotchas.md`** for the production checklist and teardown.

## 5. What the tooling itself costs

This is a *cost* tool; be honest that standing it up is not free. None of these are toolkit
fees — they are standard Azure charges you already own or newly incur. Check the Azure Pricing
Calculator for current numbers in your region; the point here is *what* has a meter, not exact
dollars.

| Component | Pattern | Cost driver |
|---|---|---|
| **Log Analytics ingestion + retention** | A and B | Priced per GB ingested and per GB retained beyond the free period. Diagnostic logs for busy model resources add up — scope categories, set retention deliberately, and consider a Basic/Analytics table plan trade-off. |
| **API Management, v2 tier** | B only | A fixed monthly platform cost per unit (Basic v2 is the cheapest v2). Pattern B needs v2 because **Anthropic Messages API support in APIM is v2-tier-only** — the `llm-*` policies themselves run on all tiers. This is the main new spend Pattern B introduces. |
| **Data Collection Endpoint / Rule** | A (enrichment) | No charge for the DCE/DCR objects themselves; you pay for the Log Analytics ingestion they feed. |
| **The models** | A and B | Your existing token spend — unchanged by this toolkit. Pattern B's Claude is Marketplace token-metered. |
| **Power BI** | optional | Per-user or capacity licensing if you use the Power BI path instead of the HTML portal. |

The irony to state out loud to a sponsor: turning on the logging that lets you *attribute* spend
itself *costs* (ingestion). For a large tenant, model the log volume before you enable it
everywhere.
