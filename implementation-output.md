# Implementation Output

**Project**: APIM MCP Server Proxy to Azure DevOps  
**Subscription**: `8b0337f7-16f0-43e3-827a-9f438eac90e9`  
**Tenant**: `1318d57f-757b-45b3-b1b0-9b3c3842774f`  
**AZD Environment**: `mcp-ado` | **Region**: `eastus`  
**Resource Group**: `rg-mcp-ado` | **Resource Token**: `ptw4lax6otj5i`

---

## Phase 1 — Project Scaffolding + Skeleton Orchestration

### Changes Made

| File | Action | Description |
|------|--------|-------------|
| `azure.yaml` | Created | AZD project config — `name: mcp-ado-apim`, infra path `infra/`, `postprovision` hook registered |
| `infra/bicepconfig.json` | Created | Declares Microsoft Graph Bicep v1.0 extension (`br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0`); suppresses `no-unused-params` and `no-hardcoded-env-urls` lint warnings |
| `infra/main.bicep` | Created | Subscription-scoped orchestration — `targetScope = 'subscription'`; creates resource group `rg-${environmentName}`; calls `managed-identity` module |
| `infra/main.parameters.json` | Created | Binds `environmentName` → `${AZURE_ENV_NAME}`, `location` → `${AZURE_LOCATION}` |
| `infra/modules/managed-identity.bicep` | Created | User-assigned managed identity `Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31`; outputs `id`, `principalId`, `clientId`, `name` |

**Deployed Resources**

| Resource | Name | Type |
|----------|------|------|
| Resource Group | `rg-mcp-ado` | `Microsoft.Resources/resourceGroups` |
| Managed Identity | `id-ptw4lax6otj5i` | `Microsoft.ManagedIdentity/userAssignedIdentities` |

### Issue Encountered

- `infra/bicepconfig.json` extension initially declared as an object (`{ "version": "..." }`). Bicep requires it as a plain string. Fixed to `"br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0"`.

### Validation Results

| Check | Result |
|-------|--------|
| `az bicep build infra/main.bicep` | ✅ Zero errors, zero warnings |
| `azd provision` | ✅ Succeeded |
| Resource group `rg-mcp-ado` exists | ✅ Confirmed via portal and CLI |
| MI `id-ptw4lax6otj5i` exists — `objectId = a50ee27c-ef68-49eb-b0d8-50e3d4ac096b`, `clientId = 7378a1fb-2381-4ce3-a0e2-fc0789ea0e58` | ✅ Confirmed |

---

## Phase 2 — Entra App Registration

### Changes Made

| File | Action | Description |
|------|--------|-------------|
| `infra/modules/entra-apps.bicep` | Created | Graph Bicep extension (`extension microsoftGraphV1`); creates `Microsoft.Graph/applications@v1.0` with `displayName: 'APIM MCP ADO Proxy'`, `signInAudience: 'AzureADMyOrg'`, `requestedAccessTokenVersion: 2`; `requiredResourceAccess` for ADO first-party app (`499b84ac-1321-427f-aa17-267ca6975798`) `user_impersonation` scope; `web.redirectUris` = `https://login.microsoftonline.com/common/oauth2/nativeclient`; also creates `Microsoft.Graph/servicePrincipals@v1.0` |
| `infra/main.bicep` | Updated | Added `entra-apps` module call (depends on `managed-identity`); added outputs `APIM_APP_CLIENT_ID`, `APIM_APP_OBJECT_ID`, `APIM_APP_SCOPE_ID` |

**Key design decisions**

- `uniqueName = 'apim-mcp-ado-proxy-${environmentName}'` — deterministic name prevents duplicate app registrations
- `userImpersonationScopeId = guid(uniqueName, 'user_impersonation')` — stable, reproducible GUID for the delegated scope
- `oauth2PermissionScopes` and `preAuthorizedApplications` intentionally **not** set in Bicep — Graph API rejects updating already-enabled scopes in a PUT/PATCH during re-deployment. These are handled idempotently in `postprovision.ps1`.

**Deployed Resources**

| Resource | Value |
|----------|-------|
| App Registration `objectId` | `b0c8f6c5-72ea-45eb-a552-ea5e688070a3` |
| App `clientId` (appId) | `36eb7a86-3565-4c53-b010-2d2dc98c5cc2` |
| Scope ID | `8b160268-d66d-53a6-84d4-9f204340e763` |

### Issues Encountered

- Two soft-deleted app registrations with the same `uniqueName` were blocking re-creation after failed test runs. Resolved by permanently deleting via `az rest DELETE /directory/deletedItems/{id}`.

### Validation Results

| Check | Result |
|-------|--------|
| `az bicep build infra/main.bicep` | ✅ Zero errors |
| `azd provision` | ✅ Succeeded |
| `az ad app show --id b0c8f6c5...` — `displayName = 'APIM MCP ADO Proxy'`, `signInAudience = 'AzureADMyOrg'` | ✅ Confirmed |
| `az ad sp show --id 36eb7a86...` — service principal exists | ✅ Confirmed |
| `requiredResourceAccess` includes ADO `user_impersonation` (`499b84ac...`) | ✅ Confirmed |

---

## Phase 3 — Post-Provision Hook

### Changes Made

| File | Action | Description |
|------|--------|-------------|
| `hooks/postprovision.ps1` | Created | Reads AZD env outputs; sets `identifierUris`; creates `user_impersonation` scope; adds `preAuthorizedApplications` for VS Code + Azure CLI; creates federated identity credential; (Phase 5 block) appends APIM callback `redirectUri` |
| `azure.yaml` | Updated | Registered `postprovision` hook: `shell: pwsh`, `run: hooks/postprovision.ps1`, `continueOnError: false`, `interactive: true` |
| `infra/main.bicep` | Updated | Added outputs `MANAGED_IDENTITY_OBJECT_ID`, `AZURE_TENANT_ID` (consumed by hook) |

**Hook logic summary** (all steps idempotent)

1. **`identifierUris`** — sets `api://{appId}` via `az ad app update`
2. **`oauth2PermissionScopes`** — checks for existing scope by ID before PATCHing Graph API
3. **`preAuthorizedApplications`** — builds merged array of VS Code (`aebc6443-...`) + Azure CLI (`04b07795-...`), skips if both already present
4. **`federated identity credential`** — queries existing creds by name `apim-managed-identity` before creating; uses `api://AzureADTokenExchange` audience, MI `objectId` as subject
5. **`callback redirectUri`** — appended when `APIM_GATEWAY_URL` is present in AZD outputs (fires in Phase 5+)

**Design decisions**

- `Invoke-GraphPatch` helper function writes JSON to a temp file and uses `az rest --body "@file"` — required to work around Windows PowerShell command-line JSON quoting issues with `az rest`
- `@()` cast on all Graph list queries to handle null returns (prevents `.Count` errors when no results exist)

### Issues Encountered

| Issue | Fix |
|-------|-----|
| `az rest --body '{...}'` — Windows PowerShell mishandles embedded quotes in JSON string arguments | Write JSON to temp `.json` file, pass `--body "@$tmp"` |
| `.Count` on null returned from Graph query when no federated credentials exist | Cast result with `@()` before calling `.Count` |
| `preAuthorizedApplications` PATCH overwrote existing entries | Build merged array from existing + new before PATCHing |
| Entra error 53003 on device code flow — Conditional Access policy blocked Azure CLI app | Added Azure CLI (`04b07795-...`) to `preAuthorizedApplications` to allow silent token acquisition |

### Validation Results

| Check | Result |
|-------|--------|
| `azd provision` (hook fires) | ✅ All 5 steps completed without error |
| `identifierUris` = `["api://36eb7a86-3565-4c53-b010-2d2dc98c5cc2"]` | ✅ Confirmed |
| Federated credential `apim-managed-identity` — `issuer = https://login.microsoftonline.com/1318d57f.../v2.0`, `subject = a50ee27c-...`, `audiences = ["api://AzureADTokenExchange"]` | ✅ Confirmed |
| Second `azd provision` — all hook steps skipped (idempotency) | ✅ Confirmed |
| `preAuthorizedApplications` includes VS Code `aebc6443-...` and Azure CLI `04b07795-...` | ✅ Confirmed |

---

## Phase 4 — APIM Instance + PRM Endpoint

### Changes Made

| File | Action | Description |
|------|--------|-------------|
| `infra/policies/prm-endpoint.xml` | Created | `return-response` policy returning RFC 9728 PRM JSON — `resource`, `authorization_servers`, `scopes_supported`, `bearer_methods_supported`, `resource_documentation`, `resource_name` populated dynamically from named values and request URL |
| `infra/modules/apim.bicep` | Created | `Microsoft.ApiManagement/service@2024-05-01` BasicV2 capacity 1; user-assigned MI; 5 named values; PRM API (path `well-known`); GET `/oauth-protected-resource` operation with policy |
| `infra/main.bicep` | Updated | Added `apim` module call; added outputs `APIM_GATEWAY_URL`, `APIM_NAME` |

**Named values provisioned**

| Named Value | Content |
|-------------|---------|
| `tenant-id` | `1318d57f-757b-45b3-b1b0-9b3c3842774f` |
| `apim-app-client-id` | `36eb7a86-3565-4c53-b010-2d2dc98c5cc2` |
| `managed-identity-client-id` | `7378a1fb-2381-4ce3-a0e2-fc0789ea0e58` |
| `ado-org` | `wegmans` |
| `ado-scope` | `499b84ac-1321-427f-aa17-267ca6975798/user_impersonation` |

**Deployed Resources**

| Resource | Value |
|----------|-------|
| APIM name | `apim-ptw4lax6otj5i` |
| APIM gateway URL | `https://apim-ptw4lax6otj5i.azure-api.net` |
| APIM SKU | BasicV2, capacity 1 |

### Issues Encountered

| Issue | Fix |
|-------|-----|
| APIM rejected API path `.well-known` — leading dot is invalid in APIM API path suffix | Changed path to `well-known`; all metadata URLs in policies adjusted accordingly (no leading dot) |
| `APIM_GATEWAY_URL` output already includes `https://` scheme; hook was prepending another `https://` when building callback URI | Added `StartsWith("https://")` check in `postprovision.ps1` before prepending scheme |
| `az apim show --query "identity"` failed with exit code 1 — query format incompatible with that property | Used `ConvertFrom-Json | Select-Object -ExpandProperty identity` instead |
| `redirectUris` appeared empty after earlier `az ad app update` call | Used Graph API PATCH with temp file to set both redirect URIs correctly |

### Validation Results

| Check | Result |
|-------|--------|
| `az bicep build infra/main.bicep` | ✅ Zero errors, zero warnings |
| `azd provision` (APIM deploy ~15 min) | ✅ Succeeded |
| APIM status `Succeeded`, SKU `BasicV2` | ✅ Confirmed |
| APIM identity type `UserAssigned` with `id-ptw4lax6otj5i` | ✅ Confirmed |
| Named values — all 5 present | ✅ Confirmed via `az apim nv list` |
| `GET /well-known/oauth-protected-resource` → HTTP 200, RFC 9728 JSON | ✅ Confirmed — response below |
| `web.redirectUris` includes `https://apim-ptw4lax6otj5i.azure-api.net/callback` | ✅ Confirmed |

**PRM endpoint response**
```json
{
  "resource": "https://apim-ptw4lax6otj5i.azure-api.net/mcp",
  "authorization_servers": ["https://login.microsoftonline.com/1318d57f-757b-45b3-b1b0-9b3c3842774f/v2.0"],
  "scopes_supported": ["api://36eb7a86-3565-4c53-b010-2d2dc98c5cc2/user_impersonation"],
  "bearer_methods_supported": ["header"],
  "resource_documentation": "https://apim-ptw4lax6otj5i.azure-api.net/well-known/oauth-protected-resource",
  "resource_name": "APIM MCP ADO Proxy"
}
```

---

## Phase 5 — APIM MCP Server (Native) + OBO Policy

### Research Finding

The plan assumed APIM MCP Servers require a separate ARM resource type (`Microsoft.ApiManagement/service/mcpServers`) or portal-only creation. **This is incorrect.** APIM MCP Servers are created as standard `Microsoft.ApiManagement/service/apis` resources with `type: 'mcp'`, supported since API version `2024-06-01-preview`. Full Bicep automation is possible — no hook or portal step needed.

Discovery method: tested `apiType: 'mcp'` and confirmed `type: 'mcp'` property round-trips via ARM. Confirmed via Azure Samples reference Bicep (`mcp-client-authorization` lab).

**MCP Server endpoint URL format**: APIM routes `POST /<path>` → backend MCP server. With `path: 'ado/mcp'`, the client endpoint is `https://apim-ptw4lax6otj5i.azure-api.net/ado/mcp`.

### Changes Made

| File | Action | Description |
|------|--------|-------------|
| `infra/policies/mcp-server-obo.xml` | Created | OBO policy applied at the `ado-mcp` API scope — token validation → user token extraction → MI assertion → OBO exchange → consent check → set ADO Bearer header |
| `infra/modules/apim.bicep` | Updated | Added `Microsoft.ApiManagement/service/backends@2024-06-01-preview` (`ado-mcp-backend`, url `https://mcp.dev.azure.com/wegmans`); added `Microsoft.ApiManagement/service/apis@2024-06-01-preview` (`ado-mcp`, `type: 'mcp'`, `path: 'ado/mcp'`, `backendId: 'ado-mcp-backend'`); added policy resource referencing `mcp-server-obo.xml`; added `adoMcpPath` output |
| `infra/policies/prm-endpoint.xml` | Updated | `resource` field changed from `gatewayUrl + "/mcp"` to `gatewayUrl + "/ado/mcp"` |
| `infra/main.bicep` | Updated | Added `APIM_MCP_URL` output (`${gatewayUrl}/${adoMcpPath}`) |

**MCP OBO policy flow**

| Step | Policy Element | Purpose |
|------|---------------|---------|
| 1 | `validate-azure-ad-token` | Validates Bearer token; accepts audience as bare GUID (`{{apim-app-client-id}}`) or `api://` prefixed form; returns 401 on failure |
| 2 | `set-variable UserToken` | Extracts raw JWT from `Authorization` header before it is overwritten |
| 3 | `authentication-managed-identity` | Acquires MI assertion token for `api://AzureADTokenExchange` using `{{managed-identity-client-id}}`; output → `MiAssertionToken` |
| 4 | `send-request OboResponse` | Posts OBO exchange (`grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`, `client_assertion_type=jwt-bearer`, `client_assertion={MI token}`, `assertion={user token}`, `scope={{ado-scope}} offline_access`) to Entra v2.0 token endpoint |
| 5 | `<choose>` | Inspects OBO status: non-200 body contains `interaction_required`/`consent_required`/`invalid_grant` → 403 + `consent_uri`; other non-200 → 502 with details |
| 6 | `set-header Authorization` | Replaces inbound `Authorization` with OBO ADO access token |
| 7 | `on-error` | Adds `WWW-Authenticate: Bearer resource_metadata="..."` header on 401 |

### Issues Encountered

| Issue | Fix |
|-------|-----|
| `<client-application-ids>` in `validate-azure-ad-token` blocked all callers — it checks the `azp` claim (client that obtained the token), which is Azure CLI `04b07795-...` or VS Code `aebc6443-...`, not our app | Removed `<client-application-ids>` block entirely; audience validation plus `preAuthorizedApplications` on the app registration is the correct enforcement layer |
| First `azd provision` created `ado-mcp` API with `path: 'ado'` (leftover exploratory REST call); Bicep updated it to `path: 'ado/mcp'` on second provision | Resolved automatically by re-running `azd provision` — ARM PUT is idempotent |
| `postprovision.ps1` hook emits `Continuous access evaluation` (CAE) errors against Graph API during re-runs — Graph token was issued before a CA policy refresh | Non-blocking — all Graph operations were already idempotent from previous phases; re-running `az login` before next provision resolves |

### Validation Results

| Check | Result |
|-------|--------|
| `az bicep build infra/main.bicep` | ✅ Zero errors (1 BCP037 warning — known Bicep type schema lag for `backendId` on MCP API type, valid at runtime) |
| `azd provision` | ✅ Succeeded |
| `ado-mcp` API: `type = mcp`, `path = ado/mcp`, `backendId = ado-mcp-backend` | ✅ Confirmed |
| `ado-mcp-backend`: `url = https://mcp.dev.azure.com/wegmans` | ✅ Confirmed |
| OBO policy XML applied to `ado-mcp` API scope | ✅ Confirmed via ARM GET |
| `GET /well-known/oauth-protected-resource` → `resource = https://apim-ptw4lax6otj5i.azure-api.net/ado/mcp` | ✅ Confirmed |
| `POST /ado/mcp` (no token) → HTTP 401, `WWW-Authenticate: Bearer resource_metadata="https://apim-ptw4lax6otj5i.azure-api.net/well-known/oauth-protected-resource"` | ✅ Confirmed |
| `POST /ado/mcp` (valid Bearer token via `az account get-access-token`) → HTTP 403 `consent_required` | ✅ Confirmed — response below |

**PRM endpoint response (updated)**
```json
{
  "resource": "https://apim-ptw4lax6otj5i.azure-api.net/ado/mcp",
  "authorization_servers": ["https://login.microsoftonline.com/1318d57f-757b-45b3-b1b0-9b3c3842774f/v2.0"],
  "scopes_supported": ["api://36eb7a86-3565-4c53-b010-2d2dc98c5cc2/user_impersonation"],
  "bearer_methods_supported": ["header"],
  "resource_documentation": "https://apim-ptw4lax6otj5i.azure-api.net/well-known/oauth-protected-resource",
  "resource_name": "APIM MCP ADO Proxy"
}
```

**403 consent_required response**
```json
{
  "error": "consent_required",
  "description": "User consent is required to access Azure DevOps. Visit consent_uri to grant access.",
  "consent_uri": "https://apim-ptw4lax6otj5i.azure-api.net/authorize"
}
```

---

## Phase 6 — Consent Flow (Authorize + Callback)

### Discovery: Admin Consent Required

During implementation, the user-consent `/oauth2/v2.0/authorize` flow was initially built as planned. When tested in a browser, Entra rejected the consent page with **"Need admin approval"** — the Wegmans tenant has a Conditional Access / consent policy that blocks users from granting delegated permissions to third-party apps. **Admin-level consent is required.**

**Adaptation**: `authorize.xml` was updated to redirect to the `/adminconsent` endpoint instead of `/oauth2/v2.0/authorize`. The admin consent callback returns `?admin_consent=True&tenant=...` (no `code` parameter), so `callback.xml` was updated to handle both scenarios: (A) admin consent callback → return success HTML, (B) auth code exchange (legacy/user consent path, retained for completeness).

### Changes Made

| File | Action | Description |
|------|--------|-------------|
| `infra/policies/authorize.xml` | Created | 302 redirect to `https://login.microsoftonline.com/{{tenant-id}}/adminconsent?client_id={{apim-app-client-id}}&redirect_uri={gateway}/callback&state={guid}` — no `scope` or `prompt` params (adminconsent endpoint doesn't use them) |
| `infra/policies/callback.xml` | Created | Dual-mode handler: if `?admin_consent=True` → return 200 success HTML; otherwise extract `?code` → MI assertion → auth code exchange → 200 success HTML or 400 error JSON |
| `infra/modules/apim.bicep` | Updated | Added `consentApi` (path `''`, root, no subscription key); `authorizeOperation` GET `/authorize`; `callbackOperation` GET `/callback`; `authorizePolicy` (loads `authorize.xml`); `callbackPolicy` (loads `callback.xml`) |

### Issue Encountered

| Issue | Fix |
|-------|-----|
| Wegmans tenant requires admin consent — user consent page shows "Need admin approval" for ADO `user_impersonation` | Updated `authorize.xml` to use `/adminconsent` endpoint instead of `/oauth2/v2.0/authorize` |
| `callback.xml` had `<!DOCTYPE html>` in `set-body` — APIM XML parser rejected with "Unexpected DTD declaration" | Wrapped all HTML response bodies in `<![CDATA[...]]>` |
| `replace_string_in_file` left old file tail appended after new `</policies>` closing tag — ARM provision failed with "There are multiple root elements. Line 134, position 6" | Rewrote file using `replace_string_in_file` targeting the full duplicate tail text |

### Current Status

**Blocked on admin consent.** All code is complete and `callback.xml` structural bug is fixed. Next steps:

1. Run `azd provision` to deploy the consent API
2. Validate:
   - `GET /authorize` → 302 to `https://login.microsoftonline.com/.../adminconsent?client_id=36eb7a86...`
   - `GET /callback?admin_consent=True&tenant=1318d57f...` → 200 success HTML
3. A Wegmans tenant admin must visit `https://apim-ptw4lax6otj5i.azure-api.net/authorize` and click **Accept** on the consent page
4. After consent: verify `GET oauth2PermissionGrants` for SP `6ae67b41-5515-4878-9c13-729e97a992ca` shows ADO `user_impersonation` grant
5. Re-run Gate 5 OBO test — should now return 200 MCP response instead of 403

**Admin consent URL**: `https://apim-ptw4lax6otj5i.azure-api.net/authorize`  
**App needing consent**: APIM MCP ADO Proxy (`36eb7a86-3565-4c53-b010-2d2dc98c5cc2`)  
**Permission**: Azure DevOps `user_impersonation` (`499b84ac-1321-427f-aa17-267ca6975798/user_impersonation`)

---

## Deployed Resource Inventory

| Resource | Name | Value |
|----------|------|-------|
| Resource Group | `rg-mcp-ado` | `eastus` |
| Managed Identity | `id-ptw4lax6otj5i` | objectId `a50ee27c-ef68-49eb-b0d8-50e3d4ac096b`, clientId `7378a1fb-2381-4ce3-a0e2-fc0789ea0e58` |
| App Registration | `APIM MCP ADO Proxy` | objectId `b0c8f6c5-72ea-45eb-a552-ea5e688070a3`, appId `36eb7a86-3565-4c53-b010-2d2dc98c5cc2` |
| APIM | `apim-ptw4lax6otj5i` | `https://apim-ptw4lax6otj5i.azure-api.net`, BasicV2 |

## File Inventory

| File | Phase | Status |
|------|-------|--------|
| `azure.yaml` | 1, 3 | ✅ Complete |
| `infra/bicepconfig.json` | 1 | ✅ Complete |
| `infra/main.bicep` | 1–5 | ✅ Complete |
| `infra/main.parameters.json` | 1 | ✅ Complete |
| `infra/modules/managed-identity.bicep` | 1 | ✅ Complete |
| `infra/modules/entra-apps.bicep` | 2 | ✅ Complete |
| `infra/modules/apim.bicep` | 4, 5, 6 | ✅ Phase 4+5+6 complete |
| `infra/policies/prm-endpoint.xml` | 4, 5 | ✅ Complete (resource URL updated to `/ado/mcp`) |
| `infra/policies/mcp-server-obo.xml` | 5 | ✅ Complete |
| `hooks/postprovision.ps1` | 3, 5 | ✅ Phase 3+5 complete |
| `infra/policies/authorize.xml` | 6 | ⚠️ Created — awaiting `azd provision` + admin consent |
| `infra/policies/callback.xml` | 6 | ⚠️ Created — awaiting `azd provision` + admin consent |
| `tools/test-auth.ps1` | 7 | ⬜ Not started |
| `tools/test-mcp.http` | 7 | ⬜ Not started |
| `.vscode/mcp.json` | 8 | ⬜ Not started |
