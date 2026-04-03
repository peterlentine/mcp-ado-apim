# Session Context: APIM MCP Server Proxy to Azure DevOps MCP
Date: April 3, 2026

---

## Goal

Build an Azure API Management (APIM) gateway that acts as a secure MCP (Model Context Protocol) proxy in front of the **Azure DevOps Remote MCP Server** (`https://mcp.dev.azure.com/wegmans`). The APIM layer adds OAuth 2.0 On-Behalf-Of (OBO) authentication, Protected Resource Metadata (PRM) discovery, and a user consent flow. The entire infrastructure is defined as code (Bicep + Microsoft Graph Bicep Extension) and deployed via Azure Developer CLI (`azd`).

---

## User-Provided Parameters

| Parameter | Value |
|-----------|-------|
| Azure Subscription ID | `8b0337f7-16f0-43e3-827a-9f438eac90e9` |
| Entra Tenant ID | `1318d57f-757b-45b3-b1b0-9b3c3842774f` |
| Azure DevOps Organization | `wegmans` |
| APIM SKU | BasicV2 |
| Resource Prefix | `mcp-ado` |
| Credential Strategy | Managed Identity (Federated Credential) |
| VS Code App ID (to pre-authorize) | `aebc6443-996d-45c2-90f0-388ff96faa56` |
| Admin consent available | No |

---

## Key External Resources Discovered

### Azure DevOps Remote MCP Server
- **Endpoint**: `https://mcp.dev.azure.com/{organization}`
- **Transport**: Streamable HTTP (not STDIO)
- **Authentication**: Microsoft Entra ID (OAuth 2.0)
- **Status**: Public preview (announced ~March 2026)
- **Tools**: Work items, repos, pull requests, pipelines, wiki, test plans, search
- **Config**:
  ```json
  {
    "servers": {
      "ado-remote-mcp": {
        "url": "https://mcp.dev.azure.com/{organization}",
        "type": "http"
      }
    }
  }
  ```
- **Toolset filtering headers**: `X-MCP-Toolsets`, `X-MCP-Readonly`, `X-MCP-Tools`
- **Source**: https://learn.microsoft.com/en-us/azure/devops/mcp-server/remote-mcp-server

### Azure DevOps Entra App ID
- **First-party app ID**: `499b84ac-1321-427f-aa17-267ca6975798`
- **OBO scope**: `499b84ac-1321-427f-aa17-267ca6975798/user_impersonation`
- This is the resource the OBO token exchange targets

### Microsoft Graph Bicep Extension
- **Registry reference**: `br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0`
- **Declared in**: `infra/bicepconfig.json` under `extensions`
- **Used in Bicep**: `extension microsoftGraphV1` at top of file
- **Supported resources**:
  - `Microsoft.Graph/applications@v1.0` — App registrations
  - `Microsoft.Graph/servicePrincipals@v1.0` — Service principals
- **Key app registration properties**:
  - `uniqueName` (required, immutable, acts as idempotency key)
  - `api.oauth2PermissionScopes` — Exposes delegated scopes
  - `api.preAuthorizedApplications` — Pre-authorizes clients (e.g. VS Code)
  - `api.requestedAccessTokenVersion: 2` — Issues v2 tokens
  - `requiredResourceAccess` — Declares downstream API permissions
  - `web.redirectUris` — OAuth redirect URIs
- **Limitation**: `federatedIdentityCredentials` not supported as a Bicep resource; must be created post-deploy via `az ad app federated-credential create`
- **Deployment**: `az deployment group create` with caller's Entra context; requires `Application.ReadWrite.All` or `Application.ReadWrite.OwnedBy`

### OBO Flow in APIM (reference article)
- Source: https://medium.com/microsoftazure/configure-on-behalf-of-flow-obo-flow-in-azure-api-management-01441c90c460
- APIM policies used: `validate-azure-ad-token` (or `validate-jwt`), `set-variable`, `authentication-managed-identity`, `send-request`, `set-header`
- Managed identity approach: Use `authentication-managed-identity` with `resource="api://AzureADTokenExchange"` to get MI assertion token, then POST to Entra token endpoint with `client_assertion` instead of `client_secret`
- OBO POST body parameters:
  - `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`
  - `client_id={APIM app client ID}`
  - `client_assertion={MI token}`
  - `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`
  - `assertion={user Bearer token}`
  - `scope={downstream API scope}`
  - `requested_token_use=on_behalf_of`

### Protected Resource Metadata (RFC 9728)
- **Well-known path**: `GET /.well-known/oauth-protected-resource`
- **Purpose**: Allows MCP clients to autodiscover which authorization server and scopes to use
- **Response shape**:
  ```json
  {
    "resource": "https://{resource-url}",
    "authorization_servers": ["https://login.microsoftonline.com/{tenant}/v2.0"],
    "scopes_supported": ["api://{client-id}/user_impersonation"],
    "bearer_methods_supported": ["header"],
    "resource_name": "Human readable name"
  }
  ```
- **WWW-Authenticate usage**: On unauthenticated requests, resource returns `401` with `WWW-Authenticate: Bearer resource_metadata="{url}"` header so clients can discover the PRM URL dynamically
- **Standard**: RFC 9728 (April 2025, IETF Standards Track)

---

## Architecture

```
MCP Client (VS Code Copilot agent mode)
  │
  ├─ [No token] GET /mcp
  │     → 401 WWW-Authenticate: Bearer resource_metadata="https://{apim}/.well-known/oauth-protected-resource"
  │
  ├─ GET /.well-known/oauth-protected-resource
  │     → 200 PRM JSON  {authorization_servers, scopes_supported, ...}
  │
  ├─ User authenticates with Entra ID (VS Code handles this silently — pre-authorized)
  │     → Access token with aud=APIM app client ID
  │
  ├─ [First call] POST /mcp  Authorization: Bearer {user-token}
  │     APIM: validate-azure-ad-token ✓
  │     APIM: OBO exchange → Entra returns interaction_required (no ADO consent yet)
  │     → 403 {"error":"consent_required","consent_uri":"https://{apim}/authorize"}
  │
  ├─ User visits GET /authorize  (one-time, in browser)
  │     APIM: 302 redirect → Entra consent page (prompt=consent, ADO scope)
  │     User grants consent
  │     Entra: 302 redirect → GET /callback?code=...
  │
  ├─ GET /callback?code=...
  │     APIM: exchanges code → gets tokens (stores consent in Entra for user)
  │     → 200 "Consent granted successfully..."
  │
  └─ [Subsequent calls] POST /mcp  Authorization: Bearer {user-token}
        APIM: validate-azure-ad-token ✓
        APIM: authentication-managed-identity → MI token
        APIM: OBO exchange → ADO access token ✓
        APIM: set Authorization: Bearer {ado-token}
        → Forward to https://mcp.dev.azure.com/wegmans
              → MCP response
```

---

## Entra ID App Registration Design

### APIM MCP Proxy App
| Property | Value |
|----------|-------|
| Display Name | `APIM MCP ADO Proxy` |
| Sign-in Audience | `AzureADMyOrg` |
| Identifier URI | `api://{appId}` (set post-deploy) |
| Token Version | v2 (`requestedAccessTokenVersion: 2`) |
| Exposed Scope | `user_impersonation` (delegated) — stable GUID generated in Bicep |
| Pre-authorized App | `aebc6443-996d-45c2-90f0-388ff96faa56` (VS Code) with `user_impersonation` permission |
| Required Access | `user_impersonation` from Azure DevOps (`499b84ac-1321-427f-aa17-267ca6975798`) |
| Redirect URIs | `https://login.microsoftonline.com/common/oauth2/nativeclient` (testing) + `https://{apim-gateway-url}/callback` (added by post-provision hook) |
| Credential | Federated Identity Credential — trusts user-assigned managed identity (subject = MI object ID, issuer = Entra v2 endpoint, audience = `api://AzureADTokenExchange`) |

### Why Pre-authorize VS Code (`aebc6443-996d-45c2-90f0-388ff96faa56`)
VS Code uses this app ID when acquiring tokens interactively. By adding it to `preAuthorizedApplications`, users are **not** prompted for a separate "APIM MCP ADO Proxy needs permission" consent screen when VS Code requests `api://{apim-app-id}/user_impersonation`. The only consent required is the downstream ADO delegation, handled by the `/authorize` + `/callback` flow.

---

## APIM Policy Summary

### `mcp-proxy.xml` (on `/mcp` API)
1. `validate-azure-ad-token` — Validates Bearer token against APIM app client ID as audience; returns 401 with PRM `WWW-Authenticate` on failure
2. `set-variable` `UserToken` — Extracts raw JWT string from Authorization header
3. `authentication-managed-identity` — Gets MI assertion token for `api://AzureADTokenExchange`
4. `send-request` — POSTs OBO exchange to Entra token endpoint
5. Checks OBO response for `interaction_required` / `invalid_grant` → returns 403 with `consent_uri`
6. `set-header` Authorization → replaces with OBO token
7. Forwards to ADO MCP backend

### `prm-endpoint.xml` (on `/.well-known/oauth-protected-resource`)
- `return-response` — Static 200 JSON with RFC 9728 PRM document

### `authorize.xml` (on `GET /authorize`)
- `return-response` — 302 redirect to Entra authorize URL:
  - `response_type=code`
  - `scope=499b84ac.../user_impersonation openid profile`
  - `prompt=consent`
  - `redirect_uri=https://{apim}/callback`
  - `state={GUID}` (CSRF protection)

### `callback.xml` (on `GET /callback`)
- `authentication-managed-identity` — Gets MI assertion token
- `send-request` — POSTs authorization code exchange to Entra token endpoint
- On success: `return-response` 200 HTML "Consent granted"
- On error: `return-response` 400 with error JSON

---

## Post-Provision Hook (`hooks/postprovision.ps1`)

Runs automatically after `azd provision`. Performs steps that cannot be done in Bicep. **Grows across phases 3 and 5**:

**Phase 3:**
1. **Set `identifierUris`** — `az ad app update --id {objectId} --identifier-uris "api://{appId}"`
2. **Create federated identity credential**:
   ```powershell
   az ad app federated-credential create --id {objectId} --parameters '{
     "name": "apim-managed-identity",
     "issuer": "https://login.microsoftonline.com/{tenantId}/v2.0",
     "subject": "{MI-objectId}",
     "audiences": ["api://AzureADTokenExchange"]
   }'
   ```

**Phase 5:**
3. **Add callback redirectUri** — Updates `web.redirectUris` to include `https://{apim-gateway-url}/callback`

**No admin consent** — Left to end-user via runtime consent flow

---

## AZD Project Structure

**IMPORTANT**: `infra/main.bicep` and `infra/modules/apim.bicep` are written **incrementally** across phases. Do not write these files in full upfront — each phase adds only the new resources needed for that phase's validation gate.

```
mcp-ado-apim/
├── azure.yaml                          # AZD config: infra path, hooks
├── infra/
│   ├── bicepconfig.json                # Graph Bicep extension declaration
│   ├── main.bicep                      # Module orchestration + outputs (grows phases 1→2→4→5)
│   ├── main.parameters.json            # Binds AZURE_ENV_NAME, AZURE_LOCATION
│   ├── modules/
│   │   ├── managed-identity.bicep      # User-assigned MI (phase 1)
│   │   ├── entra-apps.bicep            # App registration + SP (phase 2)
│   │   └── apim.bicep                  # APIM, APIs, backend (grows phases 4→5→6)
│   └── policies/
│       ├── prm-endpoint.xml            # PRM static response (phase 4)
│       ├── mcp-proxy.xml               # OBO flow policy (phase 5)
│       ├── authorize.xml               # Consent redirect (phase 6)
│       └── callback.xml                # Consent code exchange (phase 6)
├── hooks/
│   └── postprovision.ps1               # Federated cred (phase 3) + redirectUri (phase 5)
├── tools/
│   ├── test-auth.ps1                   # PowerShell auth + MCP test (phase 7)
│   └── test-mcp.http                   # REST Client test file (phase 7)
└── .vscode/
    └── mcp.json                        # VS Code MCP server config (phase 8)
```

---

## Deployment Sequence

Deploy **phase by phase** — validate before proceeding.

### Phase 1: Scaffold + MI
```powershell
azd auth login
azd env new mcp-ado
azd env set AZURE_SUBSCRIPTION_ID 8b0337f7-16f0-43e3-827a-9f438eac90e9
azd env set AZURE_LOCATION eastus
azd provision
# Validate: az identity show -g {rg} -n {mi-name}
```

### Phase 2: Entra App Reg
```powershell
azd provision
# Validate: az ad app show --id {objectId}
```

### Phase 3: Post-Provision Hook
```powershell
azd provision
# Validate: az ad app federated-credential list --id {objectId}
```

### Phase 4: APIM + PRM
```powershell
azd provision  # ~5-10 min for APIM first deploy
# Validate: curl https://{gateway}/.well-known/oauth-protected-resource
```

### Phase 5: MCP Proxy + OBO
```powershell
azd provision
# Validate: POST /mcp (no token) → 401; POST /mcp (with token) → 403 consent_required
```

### Phase 6: Consent Flow
```powershell
azd provision
# Validate: GET /authorize → 302; browser consent flow; POST /mcp → 200
```

### Phase 7: Test Tools
```powershell
# Validate: tools/test-auth.ps1 runs; test-mcp.http requests succeed
```

### Phase 8: VS Code
```powershell
# Validate: ado-via-apim appears in agent mode; ADO tools populate
```

---

## Testing Sequence

| Step | Command / Action | Expected Result |
|------|-----------------|-----------------|
| 1 | `GET /.well-known/oauth-protected-resource` | 200 PRM JSON |
| 2 | `POST /mcp` (no token) | 401 + `WWW-Authenticate` with `resource_metadata` |
| 3 | Run `tools/test-auth.ps1` | Device code flow; prints access token |
| 4 | `POST /mcp` with token (first time) | 403 `consent_required` + `consent_uri` |
| 5 | Visit `GET /authorize` in browser | 302 → Entra consent screen |
| 6 | Grant consent, redirected to `/callback` | 200 "Consent granted" HTML |
| 7 | `POST /mcp` with token (after consent) | 200 MCP `initialize` response from ADO |
| 8 | VS Code: open agent mode, select tools | ADO MCP tools visible (projects, repos, etc.) |

---

## Key Identifiers Reference

| Name | Value |
|------|-------|
| Entra Tenant ID | `1318d57f-757b-45b3-b1b0-9b3c3842774f` |
| Azure Subscription ID | `8b0337f7-16f0-43e3-827a-9f438eac90e9` |
| Azure DevOps first-party app ID | `499b84ac-1321-427f-aa17-267ca6975798` |
| VS Code app ID (pre-authorize) | `aebc6443-996d-45c2-90f0-388ff96faa56` |
| ADO Remote MCP base URL | `https://mcp.dev.azure.com/wegmans` |
| Entra token endpoint | `https://login.microsoftonline.com/1318d57f-757b-45b3-b1b0-9b3c3842774f/oauth2/v2.0/token` |
| Entra authorize endpoint | `https://login.microsoftonline.com/1318d57f-757b-45b3-b1b0-9b3c3842774f/oauth2/v2.0/authorize` |
| Federated credential audience | `api://AzureADTokenExchange` |
| PRM well-known path | `/.well-known/oauth-protected-resource` |

---

## Design Decisions Log

| # | Decision | Reason |
|---|----------|--------|
| 1 | Managed Identity (Federated Credential) for OBO client auth | No secrets to manage or rotate. User selected over Client Secret. |
| 2 | Federated credential created in post-provision hook, not Bicep | Graph Bicep v1.0 extension does not expose `federatedIdentityCredentials` as a resource type. |
| 3 | APIM BasicV2 SKU | User specified. Supports all required APIM policies. |
| 4 | Subscription key disabled on all MCP/PRM/consent APIs | OAuth Bearer is the auth mechanism; requiring a subscription key breaks standard MCP clients. |
| 5 | VS Code `aebc6443-996d-45c2-90f0-388ff96faa56` pre-authorized | Allows VS Code to silently acquire APIM tokens. Without this, users see an extra "consent for APIM app" prompt. |
| 6 | No admin consent; runtime consent via `/authorize` + `/callback` | User does not have admin consent rights. First MCP call returns 403 with `consent_uri`. User visits `/authorize` once in browser; thereafter OBO succeeds. |
| 7 | PRM as a separate APIM API with `return-response` | Keeps PRM decoupled from MCP proxy logic; no backend call needed. |
| 8 | OBO consent check returns 403 (not 401) | 401 is for authentication failures (no/invalid token). 403 with `consent_required` + `consent_uri` is a distinct authorization error that the client can act on. |
| 9 | **Incremental `main.bicep` + `apim.bicep` growth per phase** | Enables validation gates — each phase deploys only what's new. Prevents all-or-nothing deployments. |
| 10 | **APIM deployed with PRM-only first (Phase 4)** | Validates APIM is reachable with simplest possible endpoint before layering OBO complexity. |
| 11 | **Consent endpoints in separate phase from OBO (Phase 6 vs 5)** | Phase 5 can validate that OBO correctly detects missing consent (403) before wiring the fix (consent flow). |
| 12 | **Hook updated across two phases (3 and 5)** | Phase 3 does federated cred (no APIM URL yet). Phase 5 adds callback redirectUri (APIM URL now known). |

---

## Open Questions / Future Work

1. **Token caching** — OBO exchange adds ~200–400ms per request. For production: `cache-store-value` keyed by `{sub}-{scope}`, TTL = token expiry minus buffer.
2. **ADO MCP SSE streaming** — Validate that Streamable HTTP SSE chunks pass through APIM BasicV2 without buffering issues.
3. **State parameter CSRF in consent flow** — The `/authorize` policy emits a `state` GUID but APIM is stateless; `/callback` can't validate it without a cache. Acceptable for demo; for production add `cache-store-value` with 5-minute TTL.
4. **Rate limiting** — Add `rate-limit-by-key` by user `sub` claim to prevent per-user abuse.
5. **Token introspection** — Could expose APIM subscription analytics (calls per user) by emitting token sub claim as a metric dimension.
