#!/usr/bin/env bash
# =============================================================================
# Pattern B - Claude Code apiKeyHelper: mint a per-USER Entra token for the gateway.
# -----------------------------------------------------------------------------
# WHAT THIS DOES
#   Claude Code runs this (per CLAUDE_CODE_API_KEY_HELPER_TTL_MS) and sends the
#   output as the credential. The APIM policy validates it and extracts the caller
#   oid, so the human who ran `claude` is the attribution key.
#
# CRITICAL - AUDIENCE GOTCHA
#   The token's audience must match the APIM gateway's app registration
#   (CLAUDE_GATEWAY_API_SCOPE), NOT https://ai.azure.com. A token scoped to
#   ai.azure.com works against Foundry directly but is REJECTED by the gateway.
#   Claude Code sends the minted token in BOTH x-api-key and Authorization; the
#   policy reads Authorization and strips both before the backend.
#
# PREREQUISITES
#   - The developer is signed in with their own identity (`az login`).
#   - The developer holds the Claude.User app role on the gateway app registration.
#   - Env vars CLAUDE_GATEWAY_API_SCOPE and CLAUDE_GATEWAY_TENANT_ID are set
#     (see 06-claude-code-settings.json).
#
# PLACEHOLDERS TO FILL
#   None in this file - the values come from the two env vars, which you fill in
#   06-claude-code-settings.json (api://<GATEWAY_APP_ID>/.default and <TENANT_ID>).
# =============================================================================
set -euo pipefail

: "${CLAUDE_GATEWAY_API_SCOPE:?set CLAUDE_GATEWAY_API_SCOPE to the gateway scope, e.g. api://<GATEWAY_APP_ID>/.default}"
: "${CLAUDE_GATEWAY_TENANT_ID:?set CLAUDE_GATEWAY_TENANT_ID to the corporate tenant id}"

# Use --scope (v2) with an explicit --tenant so a multi-account developer cannot mint a
# wrong-tenant token. Emit ONLY the raw token (tsv) - any az warning on stdout would corrupt it.
az account get-access-token \
  --scope "$CLAUDE_GATEWAY_API_SCOPE" \
  --tenant "$CLAUDE_GATEWAY_TENANT_ID" \
  --query accessToken -o tsv 2>/dev/null

# PILOT MUST PROVE (do not assume): this runs NON-INTERACTIVELY every refresh. On a locked
# workstation, Conditional Access / device compliance / token protection (CAE) may make silent
# token acquisition fail or prompt, which stalls Claude Code. Validate on a CA-like box.
#
# Windows/PowerShell equivalent (save as claude-gateway-token.ps1 and point apiKeyHelper at it):
#   az account get-access-token --scope $env:CLAUDE_GATEWAY_API_SCOPE --tenant $env:CLAUDE_GATEWAY_TENANT_ID --query accessToken -o tsv
#
# Set CLAUDE_CODE_API_KEY_HELPER_TTL_MS BELOW the token lifetime (~60-75 min) so the helper
# re-mints before expiry; otherwise long sessions hit a mid-session 401.
