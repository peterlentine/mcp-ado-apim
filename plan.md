# Plan: APIM MCP Server Proxy to Azure DevOps MCP

## TL;DR
Create an Azure API Management gateway that proxies MCP requests to the Azure DevOps Remote MCP Server (`https://mcp.dev.azure.com/wegmans`), adding OAuth 2.0 OBO flow for secure token exchange. Infrastructure is Bicep + Microsoft Graph Bicep Extension, deployed via `azd`. **Restructured into 8 phases with validation gates** — each phase deploys incrementally and is verified before proceeding.

## Important
Before proceeding to the next step.
- All validation phases should be executed by the agent.
- Once validation is complete update the [implementation-output](implementation-output.md)
- Confirmation from the user should be granted before proceeding

## Parameters
- **Subscription**: `8b0337f7-16f0-43e3-827a-9f438eac90e9`
- **Tenant**: `1318d57f-757b-45b3-b1b0-9b3c3842774f`
- **ADO Org**: `wegmans`
- **APIM SKU**: BasicV2
- **Resource Prefix**: `mcp-ado`
- **Credential Strategy**: Managed Identity (Federated Credential)

## Architecture Flow
```
MCP Client (VS Code, etc.)
  │
  ├─ (1) POST /ado/mcp → 401 + WWW-Authenticate
  ├─ (2) GET /well-known/oauth-protected-resource → PRM JSON
  ├─ (3) User authenticates → token with APIM audience
  ├─ (4) POST /ado/mcp with Bearer token
  │
APIM Gateway (MCP Server feature)
  ├─ MCP Server policy: validate-azure-ad-token
  ├─ MCP Server policy: authentication-managed-identity → MI token
  ├─ MCP Server policy: send-request OBO exchange → Entra token endpoint
  ├─ If OBO returns interaction_required → 403 with consent_uri
  ├─ MCP Server policy: set-header Authorization with OBO token
  └─ MCP Server forwards to https://mcp.dev.azure.com/wegmans (Streamable HTTP)
```

---

## Steps

### Phase 1: Project Scaffolding + Skeleton Orchestration
*Goal: Deployable AZD project with empty module stubs that pass `bicep build`.*

1. **Create `azure.yaml`** — AZD project config with `infra/` path, hook registration for `postprovision`
2. **Create `infra/bicepconfig.json`** — Declare Microsoft Graph Bicep v1.0 extension (`br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0`)
3. **Create `infra/main.bicep`** (skeleton) — Parameters: `location`, `environmentName`, `adoOrganization` (default `'wegmans'`). Initially only contains the managed-identity module call. Outputs will grow each phase.
4. **Create `infra/main.parameters.json`** — Binds `environmentName` to `${AZURE_ENV_NAME}`, `location` to `${AZURE_LOCATION}`
5. - **APIM MCP Proxy App** (`Microsoft.Graph/applications@v1.0`):
     - `displayName`: "APIM MCP ADO Proxy", `signInAudience`: "AzureADMyOrg"
     - `api.oauth2PermissionScopes`: `user_impersonation` delegated scope (stable GUID)
     - `api.requestedAccessTokenVersion`: 2
     - `api.preAuthorizedApplications`: Pre-authorize VS Code `aebc6443-996d-45c2-90f0-388ff96faa56`
     - `requiredResourceAccess`: `user_impersonation` from Azure DevOps (`499b84ac-1321-427f-aa17-267ca6975798`)
     - `web.redirectUris`: `https://login.microsoftonline.com/common/oauth2/nativeclient` (testing)
   - **Service Principal** (`Microsoft.Graph/servicePrincipals@v1.0`)
8. **Update `infra/main.bicep`** — Add `entra-apps` module call (depends on managed-identity). Add outputs: `apimAppClientId`, `apimAppObjectId`, `apimAppId`

#### Validation Gate 2
- `bicep build infra/main.bicep` — no errors
- `azd provision` — incremental deploy adds app registration + SP
- **Verify app registration**: `az ad app show --id {appObjectId}` — confirm `displayName`, `signInAudience`, `api.oauth2PermissionScopes` includes `user_impersonation`, `api.preAuthorizedApplications` includes VS Code app ID
- **Verify service principal**: `az ad sp show --id {appId}` — exists
- **Verify requiredResourceAccess**: App shows ADO `user_impersonation` in required permissions
- **Stop**: Confirm app reg is correct before adding post-provision config

---

### Phase 3: Post-Provision Hook (Federated Credential + App Config)
*Goal: identifierUris set, federated credential created, callback redirectUri ready for later APIM phase.*

9. **Create `hooks/postprovision.ps1`**:
   - Read AZD environment outputs (`apimAppObjectId`, `apimAppId`, `managedIdentityObjectId`, `tenantId`)
   - **Set `identifierUris`**: `az ad app update --id {objectId} --identifier-uris "api://{appId}"`
   - **Create federated identity credential**: `az ad app federated-credential create --id {objectId} --parameters '{"name":"apim-managed-identity","issuer":"https://login.microsoftonline.com/{tenantId}/v2.0","subject":"{MI-objectId}","audiences":["api://AzureADTokenExchange"]}'`
   - *Note*: The callback redirectUri addition is deferred to Phase 5 when APIM gateway URL is known
10. **Update `azure.yaml`** — Register `postprovision` hook pointing to `hooks/postprovision.ps1`
11. **Update `infra/main.bicep`** — Add outputs: `managedIdentityObjectId`, `tenantId` (needed by hook)

#### Validation Gate 3
- `azd provision` — runs Bicep (no-op for existing resources) + triggers `postprovision.ps1`
- **Verify identifierUris**: `az ad app show --id {objectId} --query identifierUris` → `["api://{appId}"]`
- **Verify federated credential**: `az ad app federated-credential list --id {objectId}` → shows `apim-managed-identity` with correct `issuer`, `subject`, `audiences`
- **Verify idempotency**: Run `azd provision` again → hook should handle "already exists" gracefully (check for existing federated cred before creating)
- **Stop**: Confirm federated credential is in place before building APIM

---

### Phase 4: APIM Instance + PRM Endpoint
*Goal: APIM deployed with only the PRM (Protected Resource Metadata) API — the simplest endpoint to validate APIM is reachable.*

12. **Create `infra/policies/prm-endpoint.xml`** — `return-response` with 200 OK, Content-Type `application/json`, static RFC 9728 PRM body using named values for dynamic fields (`apim-app-client-id`, `tenant-id`)
13. **Create `infra/modules/apim.bicep`** (partial — PRM only)y"
     - `signInAudience`: "AzureADMyOrg"
     - `identifierUris`: `['api://{uniqueName}']` (set post-deploy via output)
     - `api.oauth2PermissionScopes`: Define `user_impersonation` delegated scope (generate a stable GUID for the scope ID)
    - APIM instance (`Microsoft.ApiManagement/service@2024-05-01`), SKU `BasicV2`, capacity 1
    - Assign user-managed identity
    - **Named Values**: `tenant-id`, `apim-app-client-id`, `managed-identity-client-id`, `ado-org`, `ado-scope`
    - **PRM API** (path `/.well-known`): Operation `GET /oauth-protected-resource`, no subscription key, `prm-endpoint.xml` policy
    - *No MCP proxy API yet, no backend yet, no consent APIs yet*
14. **Update `infra/main.bicep`** — Add `apim` module call (depends on entra-apps, managed-identity). Add output: `apimGatewayUrl`

#### Validation Gate 4
- `bicep build infra/main.bicep` — no errors
- `azd provision` — deploys APIM instance (~5-10 min for BasicV2)
- **Verify APIM exists**: `az apim show -g {rg} -n {apim-name}` → status Running, SKU BasicV2
- **Verify MI assigned**: APIM identity includes the user-assigned MI
- **Verify PRM endpoint**: `curl https://{apim-gateway-url}/.well-known/oauth-protected-resource` → 200 JSON with correct `authorization_servers`, `scopes_supported`, `resource`
- **Verify named values**: `az apim nv list -g {rg} -n {apim-name}` → all 5 named values present
- **Stop**: Confirm APIM is reachable and PRM returns correct metadata before adding auth policies

---

### Phase 5: Create APIM MCP Server (Expose Existing MCP Server)
*Goal: Use the built-in APIM MCP Servers feature to expose the Azure DevOps MCP server (`https://mcp.dev.azure.com/wegmans`) as a managed MCP server with OBO policy.*

**Prerequisite**: Execute `revert.md` first to remove the old MCP Proxy API.

**Important**: The APIM MCP Servers feature does NOT have a Bicep/ARM resource type. MCP Server creation and policy configuration must be done via the APIM management REST API or Azure portal. This phase uses `hooks/postprovision.ps1` to automate creation.

15. **Research APIM MCP Server management API** — Determine the correct REST API endpoint and API version for creating MCP servers programmatically:
    - Try APIM configuration API: `PUT /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ApiManagement/service/{apim}/mcpServers/{name}?api-version={ver}`
    - If no ARM API exists, use the APIM direct management API or fall back to portal creation
    - Document the API contract for the MCP Server resource

16. **Update `hooks/postprovision.ps1`** — Add MCP Server creation step (idempotent):
    - **Create MCP Server**: `PUT` to the MCP Server API endpoint with:
      - `name`: `ado-mcp`
      - `backendUrl`: `https://mcp.dev.azure.com/wegmans`
      - `transportType`: `streamableHttp`
      - `basePath`: `ado`
      - `description`: `Azure DevOps Remote MCP Server (wegmans org)`
    - If the MCP Server management API is not available programmatically, document portal steps as a manual prerequisite
    - The resulting MCP Server endpoint will be: `https://apim-ptw4lax6otj5i.azure-api.net/ado/mcp`

17. **Create `infra/policies/mcp-server-obo.xml`** — OBO policy applied at the MCP Server scope:
    - `validate-azure-ad-token`: tenant-id, audiences = `{{apim-app-client-id}}` + `api://{{apim-app-client-id}}`, `failed-validation-httpcode="401"`
    - `set-variable UserToken`: extract Bearer JWT from Authorization header
    - `authentication-managed-identity`: resource `api://AzureADTokenExchange`, client-id `{{managed-identity-client-id}}`, output `MiAssertionToken`
    - `send-request` OBO exchange to Entra token endpoint: `grant_type=jwt-bearer`, `client_assertion={MI token}`, `assertion={user token}`, `scope={{ado-scope}}`, `requested_token_use=on_behalf_of`
    - OBO consent check: if response contains `interaction_required`/`invalid_grant`/`consent_required` → return 403 with `consent_uri`
    - On success: `set-header Authorization` with OBO ADO token
    - `on-error`: add `WWW-Authenticate: Bearer resource_metadata="..."` on 401
    - **Important**: Do NOT access `context.Response.Body` — this breaks MCP streaming

18. **Apply MCP Server policy** — Use the APIM REST API or portal to set the policy XML at the MCP Server scope:
    - Upload `infra/policies/mcp-server-obo.xml` as the policy for the `ado-mcp` MCP Server
    - Automate via `hooks/postprovision.ps1` if API supports it

19. **Update PRM endpoint** — Update `infra/policies/prm-endpoint.xml` to point `resource` to the new MCP Server URL:
    - `resource`: `https://{gateway}/ado/mcp` (was `/mcp`)

#### Validation Gate 5
- `azd provision` — succeeds, MCP Server created (or manual portal step completed)
- **Verify MCP Server exists**: Check APIM portal → APIs → MCP Servers → `ado-mcp` listed
- **Verify MCP Server URL**: `https://apim-ptw4lax6otj5i.azure-api.net/ado/mcp`
- **Verify PRM updated**: `GET /well-known/oauth-protected-resource` → `resource` field points to `/ado/mcp`
- **Verify 401 (no token)**: `POST /ado/mcp` with no Authorization → 401 + `WWW-Authenticate` header with `resource_metadata`
- **Verify 403 (consent_required)**: Acquire user token via `az account get-access-token --resource api://{appId}`, `POST /ado/mcp` with Bearer token → 403 `consent_required` with `consent_uri`
- **Verify OBO policy applied**: Policy XML visible in portal under MCP Server → Policies
- **Stop**: Confirm MCP Server exists and OBO policy intercepts requests correctly before adding consent flow

---

### Phase 6: Consent Flow (Authorize + Callback)
*Goal: Complete the consent loop. After this phase, the full auth flow works end-to-end.*

20. **Create `infra/policies/authorize.xml`** — Consent initiation policy: ✅ DONE
    - ~~Build Entra authorize URL with `prompt=consent`~~ **UPDATED**: Wegmans tenant requires admin consent — redirects to `/adminconsent` endpoint instead
    - `return-response` 302 to `https://login.microsoftonline.com/{{tenant-id}}/adminconsent?client_id={{apim-app-client-id}}&redirect_uri={gateway}/callback&state={guid}`

21. **Create `infra/policies/callback.xml`** — Consent callback policy: ✅ DONE
    - Dual-mode: if `?admin_consent=True` → 200 success HTML (no token exchange needed for admin consent)
    - Otherwise: extract `?code` → MI assertion → auth code exchange → 200 HTML or 400 JSON
    - ⚠️ Bug fixed: duplicate `</policies>` root from failed `replace_string_in_file` operation — corrected by rewriting file

22. **Update `infra/modules/apim.bicep`** — Add Consent API: ✅ DONE
    - `consentApi` (path `''`, root) with `GET /authorize` + `GET /callback`, no subscription key

#### Validation Gate 6 — ⚠️ BLOCKED (awaiting admin consent)

**Remaining steps before gate can pass:**
1. Run `azd provision` — deploys consent API (callback.xml structural bug now fixed)
2. Validate endpoints:
   - `GET /authorize` → 302 to `https://login.microsoftonline.com/1318d57f.../adminconsent?client_id=36eb7a86...`
   - `GET /callback?admin_consent=True&tenant=1318d57f...` → 200 HTML "Admin consent granted"
3. **MANUAL STEP — Admin required**: Wegmans tenant admin must visit `https://apim-ptw4lax6otj5i.azure-api.net/authorize` and click **Accept** on the Entra admin consent page
   - App: **APIM MCP ADO Proxy** (`36eb7a86-3565-4c53-b010-2d2dc98c5cc2`)
   - Permission needed: Azure DevOps `user_impersonation` (`499b84ac-1321-427f-aa17-267ca6975798`)
4. After consent granted, verify OAuth permission grants:
   ```powershell
   az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/6ae67b41-5515-4878-9c13-729e97a992ca/oauth2PermissionGrants"
   # Expect: entry with resourceId matching ADO SP, scope "user_impersonation"
   ```
5. **Verify OBO now succeeds**:
   ```powershell
   $tok = az account get-access-token --resource "api://36eb7a86-3565-4c53-b010-2d2dc98c5cc2" --query accessToken -o tsv
   curl -si -X POST "https://apim-ptw4lax6otj5i.azure-api.net/ado/mcp" `
     -H "Content-Type: application/json" `
     -H "Authorization: Bearer $tok" `
     -d '{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}},"id":1}'
   # Expect: 200 with MCP initialize response from ADO
   ```
- **Stop**: Confirm the full authentication + OBO + proxy chain works end-to-end before building test tooling

---

### Phase 7: Testing Tools
*Goal: Automated and semi-automated test scripts for repeatable validation.*

23. **Create `tools/test-auth.ps1`** — PowerShell test script:
    - Acquires user token via `az account get-access-token --resource api://{appId}`
    - Validates PRM endpoint response
    - Sends MCP `initialize` request with Bearer token to `/ado/mcp`
    - Handles `consent_required` by printing `consent_uri`
    - Prints decoded token claims (`aud`, `sub`, `scp`, `exp`)

24. **Create `tools/test-mcp.http`** — REST Client `.http` file:
    - Variables: `@apimUrl`, `@tenantId`, `@clientId`, `@token`
    - Request 1: `GET {{apimUrl}}/well-known/oauth-protected-resource`
    - Request 2: `GET {{apimUrl}}/authorize`
    - Request 3: `POST {{apimUrl}}/ado/mcp` with MCP `initialize`
    - Request 4: `POST {{apimUrl}}/ado/mcp` with MCP `tools/list`

#### Validation Gate 7
- `tools/test-auth.ps1` runs to completion — acquires token, hits PRM, sends MCP request, prints claims
- `tools/test-mcp.http` — each request returns expected status (200 PRM, 302 authorize, 200 MCP responses)
- **Stop**: Confirm test tooling works before configuring VS Code integration

---

### Phase 8: VS Code MCP Integration
*Goal: Configure VS Code to use the APIM-proxied ADO MCP server in agent mode.*

25. **Create `.vscode/mcp.json`** — MCP server configuration:
    ```json
    {
      "servers": {
        "ado-via-apim": {
          "type": "http",
          "url": "https://apim-ptw4lax6otj5i.azure-api.net/ado/mcp"
        }
      }
    }
    ```

#### Validation Gate 8 (Final)
- Open VS Code, switch to Copilot agent mode
- Verify MCP server `ado-via-apim` appears in the server list
- Verify ADO MCP tools populate (projects, repos, work items, pipelines, etc.)
- Execute a sample tool invocation (e.g., list projects) → returns results from ADO

---

## Relevant Files

| File | Phase | Purpose |
|------|-------|---------|
| `azure.yaml` | 1, 3 | AZD config, infra path, hook registration |
| `infra/bicepconfig.json` | 1 | Microsoft Graph Bicep v1.0 extension |
| `infra/main.bicep` | 1–4 | Module orchestration + outputs |
| `infra/main.parameters.json` | 1 | Binds AZD env vars |
| `infra/modules/managed-identity.bicep` | 1 | User-assigned MI |
| `infra/modules/entra-apps.bicep` | 2 | App registration + SP (Graph Bicep) |
| `infra/modules/apim.bicep` | 4, 6 | APIM instance, named values, PRM API, consent API |
| `infra/policies/prm-endpoint.xml` | 4, 5 | RFC 9728 PRM static response |
| `infra/policies/mcp-server-obo.xml` | 5 | OBO flow policy for MCP Server scope |
| `infra/policies/authorize.xml` | 6 | Consent redirect |
| `infra/policies/callback.xml` | 6 | Consent code exchange |
| `hooks/postprovision.ps1` | 3, 5 | identifierUris, federated cred, MCP Server creation, MCP Server policy |
| `tools/test-auth.ps1` | 7 | PowerShell auth + MCP test |
| `tools/test-mcp.http` | 7 | REST Client test file |
| `.vscode/mcp.json` | 8 | VS Code MCP server config |
| `revert.md` | — | Steps to remove old MCP Proxy API (run before Phase 5) |

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Managed Identity (federated credential) over client secret | User selected. No secrets to rotate/leak. |
| Federated credential in post-provision hook | Graph Bicep doesn't support `federatedIdentityCredentials`. |
| APIM BasicV2 SKU | Per user request. Supports all required policies including MCP Servers. |
| APIM MCP Servers feature over custom API proxy | Native MCP transport support (Streamable HTTP), no manual operation definitions, proper MCP protocol handling by APIM runtime. |
| MCP Server created via hook/API, not Bicep | `Microsoft.ApiManagement/service/mcpServers` ARM resource type does not exist yet. Must use APIM management API or portal. |
| VS Code `aebc6443-996d-45c2-90f0-388ff96faa56` pre-authorized | Silent token acquisition for VS Code users. |
| Azure CLI `04b07795-8ddb-461a-bbee-02f9e1bf7b46` pre-authorized | Enables `az account get-access-token` for testing. |
| Admin consent via `/adminconsent` endpoint | Wegmans tenant blocks user-level consent for ADO delegated permissions — Conditional Access policy requires admin approval. Adapted `/authorize` to redirect to `/adminconsent` endpoint. Admin visits `https://apim-ptw4lax6otj5i.azure-api.net/authorize` once to grant tenant-wide consent. |
| OBO consent failure returns 403 (not 401) | 401 = missing/invalid auth. 403 = authorized but consent needed. |
| Do NOT access `context.Response.Body` in MCP Server policies | Triggers response buffering that breaks MCP streaming transport. |
| PRM endpoint kept as separate Bicep API (not on MCP Server) | PRM is a standard REST endpoint, not an MCP protocol endpoint. Bicep manages it normally. |

## Further Considerations

1. **Token caching** — OBO adds ~200–400ms per request. For production: `cache-store-value` keyed by `{sub}-{scope}`. Not in initial scope.
2. **ADO MCP SSE streaming** — Validate during Phase 7 that Streamable HTTP passes through APIM without buffering.
3. **State parameter CSRF** — `/authorize` emits `state` GUID but `/callback` can't validate it without cache. Acceptable for demo.
4. **Rate limiting** — `rate-limit-by-key` by MCP session ID claim. Not in initial scope.
5. **MCP Server Bicep support** — Monitor for `Microsoft.ApiManagement/service/mcpServers` ARM resource type availability. When available, move MCP Server creation from hook to Bicep.