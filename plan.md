# Plan: APIM MCP Server Proxy to Azure DevOps MCP

## TL;DR
Create an Azure API Management gateway that proxies MCP requests to the Azure DevOps Remote MCP Server (`https://mcp.dev.azure.com/wegmans`), adding OAuth 2.0 OBO flow for secure token exchange. Infrastructure is Bicep + Microsoft Graph Bicep Extension, deployed via `azd`. **Restructured into 8 phases with validation gates** — each phase deploys incrementally and is verified before proceeding.

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
  ├─ (1) GET /mcp → 401 + WWW-Authenticate
  ├─ (2) GET /.well-known/oauth-protected-resource → PRM JSON
  ├─ (3) User authenticates → token with APIM audience
  ├─ (4) POST /mcp with Bearer token
  │
APIM Gateway
  ├─ validate-azure-ad-token
  ├─ authentication-managed-identity → MI token
  ├─ send-request OBO exchange → Entra token endpoint
  ├─ If OBO returns interaction_required → 403 with consent_uri
  ├─ Set Authorization with OBO token
  └─ Forward to https://mcp.dev.azure.com/wegmans
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

### Phase 5: APIM MCP Proxy API + OBO Policy
*Goal: MCP endpoint that validates tokens, performs OBO exchange, and proxies to ADO. Consent flow not yet wired — expect 401 (no token) or 403 (consent_required) at this stage.*

15. **Create `infra/policies/mcp-proxy.xml`** — Full OBO i
   - **PRM API** (path: `/.well-known`):
     - Operation: `GET /oauth-protected-resource`
     - Subscription key not required
     - Apply `prm-endpoint.xml` policy (returns static PRM JSON)
   - **Consent API** (path: `/`):
     - Operation: `GET /authorize` — initiates user consent flow
     - Operation: `GET /callback` — handles Entra ID redirect after consent
     - Subscription key not required
     - Apply `authorize.xml` and `callback.xml` policies respectively

### Phase 4: APIM Policies

7. **Create `infra/policies/mcp-proxy.xml`** — Inbound policy:
   - `validate-azure-ad-token` with `tenant-id`, required claim `aud` = APIM app client ID, `output-token-variable-name="jwt"`, `failed-validation-httpcode="401"`
   - On-error (no/invalid token): Return 401 with `WWW-Authenticate: Bearer resource_metadata="https://{apim-gateway-url}/.well-known/oauth-protected-resource"`
   - `set-variable` to extract Bearer token string from Authorization header
   - `authentication-managed-identity` with `resource="api://AzureADTokenExchange"` and `client-id={MI client ID}`, output to `miToken`
   - `send-request` to `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token`:
     - `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`
     - `client_id={APIM app client ID}`
     - `client_assertion={miToken}`
    - `validate-azure-ad-token`: `tenant-id`, `aud` = APIM app client ID, `output-token-variable-name="jwt"`
    - On-error: 401 + `WWW-Authenticate: Bearer resource_metadata="https://{gateway}/.well-known/oauth-protected-resource"`
    - `set-variable` `UserToken` — extract Bearer JWT from Authorization header
    - `authentication-managed-identity` — `resource="api://AzureADTokenExchange"`, `client-id={MI client ID}`, output `miToken`
    - `send-request` OBO POST to Entra token endpoint with `grant_type=jwt-bearer`, `client_assertion={miToken}`, `assertion={user token}`, `scope=499b84ac.../user_impersonation`, `requested_token_use=on_behalf_of`
    - OBO consent check: if response contains `interaction_required` or `invalid_grant` → return 403 with `{"error":"consent_required","consent_uri":"https://{gateway}/authorize"}`
    - On success: `set-header Authorization` with OBO token, forward to backend
16. **Update `infra/modules/apim.bicep`** — Add:
    - **Backend**: `https://mcp.dev.azure.com/wegmans`
    - **MCP Proxy API** (path `/mcp`): Wildcard `POST /*` and `GET /*`, no subscription key, backend = ADO MCP, policy = `mcp-proxy.xml`
17. **Update `hooks/postprovision.ps1`** — Add step to append `https://{apim-gateway-url}/callback` to `web.redirectUris` (reads `apimGatewayUrl` from AZD env outputs). Needed for Phase 6 but safe to add now.

#### Validation Gate 5
- `bicep build infra/main.bicep` — no errors (verify policy XML is valid by deploying)
- `azd provision` — incremental deploy adds MCP API + backend
- **Verify 401 (no token)**: `curl -s -o /dev/null -w "%{http_code}" -X POST https://{apim-url}/mcp` → `401`
- **Verify WWW-Authenticate header**: Response includes `resource_metadata` pointing to PRM URL
- **Verify 403 (consent_required)**: Acquire a user token via `az account get-access-token --resource api://{appId}` (or device code flow), send `POST /mcp` with Bearer token → 403 with `{"error":"consent_required","consent_uri":"..."}` (expected — user hasn't consented to ADO delegation yet)
- **Verify backend configured**: `az apim api show -g {rg} -n {apim-name} --api-id mcp-proxy` → exists, backend set
- **Verify redirectUri updated**: `az ad app show --id {objectId} --query web.redirectUris` → includes callback URL
- **Stop**: Confirm OBO flow reaches Entra and correctly detects missing consent before adding consent endpoints

---

### Phase 6: Consent Flow (Authorize + Callback)
*Goal: Complete the consent loop. After this phase, the full auth flow works end-to-end.*

18. **Create `infra/policies/authorize.xml`** — Consent initiationize URL

10. **Create `infra/policies/callback.xml`** — Consent callback policy:
    - Inbound: Extract `code` query parameter
    - `authentication-managed-identity` to get MI token for `api://AzureADTokenExchange`
    - `send-request` to `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token`:
      - `grant_type=authorization_code`
      - `client_id={apim-app-client-id}`
      - `code={authorization_code}`
      - `redirect_uri=https://{apim-gateway-url}/callback`
      - `client_assertion={MI token}`
    - Build Entra authorize URL with `client_id`, `response_type=code`, `redirect_uri=https://{gateway}/callback`, `scope=499b84ac.../user_impersonation openid profile`, `prompt=consent`, `state={GUID}`
    - `return-response` 302 redirect
19. **Create `infra/policies/callback.xml`** — Consent callback:
    - Extract `code` query param
    - `authentication-managed-identity` → MI token
    - `send-request` auth code exchange to Entra token endpoint (`grant_type=authorization_code`, `client_assertion={MI token}`)
    - On success: 200 HTML "Consent granted successfully. You can close this window and retry your MCP request."
    - On error: 400 with error JSON
20. **Update `infra/modules/apim.bicep`** — Add:
    - **Consent API** (path `/`): `GET /authorize` with `authorize.xml`, `GET /callback` with `callback.xml`, no subscription key

#### Validation Gate 6
- `bicep build infra/main.bicep` — no errors
- `azd provision` — incremental deploy adds consent API operations
- **Verify authorize redirect**: `curl -s -o /dev/null -w "%{http_code}" https://{apim-url}/authorize` → `302`
- **Verify redirect URL**: Response `Location` header points to `login.microsoftonline.com/...` with correct `client_id`, `scope`, `prompt=consent`, `redirect_uri`
- **End-to-end consent test** (manual, in browser):
  1. Visit `https://{apim-url}/authorize` → redirected to Entra consent page
  2. Grant ADO `user_impersonation` consent
  3. Redirected to `/callback?code=...` → "Consent granted successfully" HTML
- **Verify OBO now succeeds**: Acquire fresh user token, `POST /mcp` with Bearer token → 200 with MCP `initialize` response from ADO (or other valid MCP response)
- **Stop**: Confirm the full authentication + OBO + proxy chain works before building test tooling

---

### Phase 7: Testing Tools
*Goal: Automated and semi-automated test scripts for repeatable validation.*

21    "servers": {
        "ado-via-apim": {
          "url": "https://{apim-gateway-url}/mcp",
          "type": "http"
        }
      }
    }
    ```

## Relevant Files

| File | Purpose |
|------|---------|
| `azure.yaml` | AZD project config, infra path, hook registration |
| `infra/bicepconfig.json` | Microsoft Graph Bicep v1.0 extension declaration |
| `infra/main.bicep` | Orchestrates all modules, outputs key values |
| `infra/main.parameters.json` | Binds AZD env vars to Bicep parameters |
| `infra/modules/entra-apps.bicep` | App registration + service principal (Graph Bicep `Microsoft.Graph/applications@v1.0`) |
| `infra/modules/managed-identity.bicep` | User-assigned managed identity for APIM |
| `infra/modules/apim.bicep` | APIM instance, APIs, backend, named values, policy attachments |
| `infra/policies/mcp-proxy.xml` | OBO flow: validate → MI token → OBO exchange → consent check → forward |
| `infra/policies/prm-endpoint.xml` | RFC 9728 Protected Resource Metadata static JSON response |
| `infra/policies/authorize.xml` | Consent initiation: 302 redirect to Entra with `prompt=consent` + ADO scope |
| `infra/policies/callback.xml` | Consent callback: exchanges auth code, returns success HTML |
| `hooks/postprovision.ps1` | Sets identifierUris, adds callback redirectUri, creates federated credential |
| `tools/test-auth.ps1` | Acquires user token, vali outputs
    - Acquires user token via device code flow
    - Validates PRM endpoint response
    - Sends MCP `initialize` request with Bearer token
    - Handles `consent_required` by printing `consent_uri`
    - Prints decoded token claims (`aud`, `sub`, `scp`, `exp`)
22. **Create `tools/test-mcp.http`** — REST Client `.http` file:
    - Variables: `@apimUrl`, `@tenantId`, `@clientId`, `@token`
    - Request 1: `GET {{apimUrl}}/.well-known/oauth-protected-resource`
    - Request 2: `GET {{apimUrl}}/authorize`
    - Request 3: `POST {{apimUrl}}/mcp` with MCP `initialize`
    - Request 4: `POST {{apimUrl}}/mcp` with MCP `tools/list`

#### Validation Gate 7
- `tools/test-auth.ps1` runs to completion — acquires token, hits PRM, sends MCP request, prints claims
- `tools/test-mcp.http` — each request returns expected status (200 PRM, 302 authorize, 200 MCP responses)
- **Stop**: Confirm test tooling works before configuring VS Code integration

---

### Phase 8: VS Code MCP Integration
*Goal: Configure VS Code to use the APIM-proxied ADO MCP server in agent mode.*

23## Validation Gate 8 (Final)
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
| `infra/main.bicep` | 1, 2, 4, 5 | Module orchestration + outputs (grows each phase) |
| `infra/main.parameters.json` | 1 | Binds AZD env vars |
| `infra/modules/managed-identity.bicep` | 1 | User-assigned MI |
| `infra/modules/entra-apps.bicep` | 2 | App registration + SP (Graph Bicep) |
| `infra/modules/apim.bicep` | 4, 5, 6 | APIM instance, APIs, backend (grows each phase) |
| `infra/policies/prm-endpoint.xml` | 4 | RFC 9728 PRM static response |
| `infra/policies/mcp-proxy.xml` | 5 | OBO flow policy |
| `infra/policies/authorize.xml` | 6 | Consent redirect |
| `infra/policies/callback.xml` | 6 | Consent code exchange |
| `hooks/postprovision.ps1` | 3, 5 | identifierUris + federated cred (phase 3), redirectUri (phase 5) |
| `tools/test-auth.ps1` | 7 | PowerShell auth + MCP test |
| `tools/test-mcp.http` | 7 | REST Client test file |
| `.vscode/mcp.json` | 8 | VS Code MCP server config |Managed Identity (federated credential) over client secret | User selected. No secrets to rotate/leak. |
| Federated credential in post-provision hook | Graph Bicep doesn't support `federatedIdentityCredentials`. |
| APIM BasicV2 SKU | Per user request. Supports all required policies. |
| VS Code `aebc6443-996d-45c2-90f0-388ff96faa56` pre-authorized | Silent token acquisition for VS Code users. |
| User consent via `/authorize` + `/callback` (no admin consent) | User lacks admin consent rights. Runtime consent flow. |
| Subscription key disabled on all APIs | OAuth Bearer is the auth mechanism; sub keys break MCP clients. |
| OBO consent failure returns 403 (not 401) | 401 = missing/invalid auth. 403 = authorized but consent needed. |
| Incremental `main.bicep` + `apim.bicep` growth per phase | Enables validation gates — each phase deploys only what's new. |
| APIM deployed with PRM-only first (Phase 4) | Validates APIM is reachable before layering auth complexity. |

## Further Considerations

1. **Token caching** — OBO adds ~200–400ms per request. For production: `cache-store-value` keyed by `{sub}-{scope}`. Not in initial scope.
2. **ADO MCP SSE streaming** — Validate during Phase 6 that Streamable HTTP passes through APIM without buffering.
3. **State parameter CSRF** — `/authorize` emits `state` GUID but `/callback` can't validate it without cache. Acceptable for demo.
4. **Rate limiting** — `rate-limit-by-key` by user `sub` claim. Not in initial scope