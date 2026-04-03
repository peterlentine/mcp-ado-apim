# Plan: APIM MCP Server Proxy to Azure DevOps MCP

## TL;DR
Create an Azure API Management gateway that proxies MCP (Model Context Protocol) requests to the Azure DevOps Remote MCP Server (`https://mcp.dev.azure.com/wegmans`), adding OAuth 2.0 OBO (On-Behalf-Of) flow for secure token exchange. Users authenticate against the APIM app registration; APIM validates the token, exchanges it via OBO for an Azure DevOps token using a managed identity federated credential, then forwards the request. APIM also serves Protected Resource Metadata (RFC 9728) so MCP clients can auto-discover auth requirements. Infrastructure is deployed via Azure Developer CLI with Bicep + Microsoft Graph Bicep Extension.

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
  ├─ (1) GET /mcp → 401 + WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource"
  ├─ (2) GET /.well-known/oauth-protected-resource → PRM JSON (authorization_servers, scopes, etc.)
  ├─ (3) User authenticates with Entra ID → token with APIM audience
  ├─ (4) POST /mcp with Bearer token
  │
APIM Gateway (apim-mcp-ado-{env}.azure-api.net)
  ├─ validate-azure-ad-token (verify APIM audience)
  ├─ Extract user token into variable
  ├─ authentication-managed-identity → get MI token for api://AzureADTokenExchange
  ├─ send-request OBO exchange → Entra ID token endpoint
  │   (client_assertion=MI token, assertion=user token, scope=ADO)
  ├─ If OBO returns interaction_required → return 403 with consent_uri
  ├─ Set Authorization header with OBO token
  └─ Forward to https://mcp.dev.azure.com/wegmans
       │
Azure DevOps Remote MCP Server
```

## Steps

### Phase 1: Project Scaffolding

1. **Initialize AZD project** — Create `azure.yaml` with infra path pointing to `./infra`, environment name `mcp-ado`, and metadata.

2. **Create Bicep configuration** — `infra/bicepconfig.json` declaring the Microsoft Graph Bicep v1.0 extension (`br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:1.0.0`).

3. **Create project folder structure**:
   ```
   mcp-ado-apim/
   ├── azure.yaml
   ├── infra/
   │   ├── bicepconfig.json
   │   ├── main.bicep
   │   ├── main.parameters.json
   │   ├── modules/
   │   │   ├── apim.bicep
   │   │   ├── managed-identity.bicep
   │   │   └── entra-apps.bicep
   │   └── policies/
   │       ├── mcp-proxy.xml
   │       ├── prm-endpoint.xml
   │       ├── authorize.xml
   │       └── callback.xml
   ├── tools/
   │   ├── test-auth.ps1
   │   ├── test-mcp.http
   │   └── setup-federated-credential.ps1
   ├── .vscode/
   │   ├── mcp.json
   │   └── settings.json
   └── hooks/
       └── postprovision.ps1
   ```

### Phase 2: Entra ID App Registrations (Bicep + Microsoft Graph Extension)

4. **Create `infra/modules/entra-apps.bicep`** — Using `extension microsoftGraphV1`:
   - **APIM MCP Proxy App** (`Microsoft.Graph/applications@v1.0`):
     - `displayName`: "APIM MCP ADO Proxy"
     - `signInAudience`: "AzureADMyOrg"
     - `identifierUris`: `['api://{uniqueName}']` (set post-deploy via output)
     - `api.oauth2PermissionScopes`: Define `user_impersonation` delegated scope (generate a stable GUID for the scope ID)
     - `api.requestedAccessTokenVersion`: 2
     - `api.preAuthorizedApplications`: Pre-authorize VS Code app `aebc6443-996d-45c2-90f0-388ff96faa56` with the `user_impersonation` delegated permission ID — allows VS Code to silently acquire tokens without a separate APIM consent prompt
     - `requiredResourceAccess`: Request delegated permission `user_impersonation` from Azure DevOps (`resourceAppId: 499b84ac-1321-427f-aa17-267ca6975798`)
     - `web.redirectUris`: Include `https://login.microsoftonline.com/common/oauth2/nativeclient` for testing AND `https://{apim-gateway-url}/callback` (added by post-provision hook)
   - **Service Principal** (`Microsoft.Graph/servicePrincipals@v1.0`): Create for the APIM app

5. **Create `infra/modules/managed-identity.bicep`**:
   - User-assigned managed identity (`Microsoft.ManagedIdentity/userAssignedIdentities`)
   - Output: `principalId`, `clientId`, `resourceId`

### Phase 3: APIM Infrastructure (Bicep)

6. **Create `infra/modules/apim.bicep`**:
   - APIM instance (`Microsoft.ApiManagement/service@2024-05-01`), SKU `BasicV2`, capacity 1
   - Assign user-managed identity to APIM
   - **Named Values** (for policy parameterization):
     - `tenant-id`: `1318d57f-757b-45b3-b1b0-9b3c3842774f`
     - `apim-app-client-id`: Output from entra-apps module
     - `managed-identity-client-id`: Output from managed-identity module
     - `ado-org`: `wegmans`
     - `ado-scope`: `499b84ac-1321-427f-aa17-267ca6975798/user_impersonation`
   - **Backend** pointing to `https://mcp.dev.azure.com/wegmans`
   - **MCP Proxy API** (path: `/mcp`):
     - Wildcard operations: `POST /*` and `GET /*`
     - Subscription key not required
     - Set backend to ADO MCP
     - Apply `mcp-proxy.xml` policy (OBO flow)
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
     - `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`
     - `assertion={user token}`
     - `scope=499b84ac-1321-427f-aa17-267ca6975798/user_impersonation`
     - `requested_token_use=on_behalf_of`
   - **OBO consent check**: Parse OBO response. If `error` is `interaction_required` or `invalid_grant`:
     - Return **403** with JSON body:
       ```json
       {
         "error": "consent_required",
         "consent_uri": "https://{apim-gateway-url}/authorize",
         "message": "User must grant consent for Azure DevOps access. Visit consent_uri in a browser, then retry."
       }
       ```
   - On OBO success: `set-header` to replace `Authorization` with `Bearer {obo_access_token}`, forward to backend

8. **Create `infra/policies/prm-endpoint.xml`** — Inbound policy:
   - `return-response` with 200 OK
   - Content-Type: `application/json`
   - Body (RFC 9728 Protected Resource Metadata):
     ```json
     {
       "resource": "https://{apim-gateway-url}/mcp",
       "authorization_servers": ["https://login.microsoftonline.com/1318d57f-757b-45b3-b1b0-9b3c3842774f/v2.0"],
       "scopes_supported": ["api://{apim-app-client-id}/user_impersonation"],
       "bearer_methods_supported": ["header"],
       "resource_name": "Azure DevOps MCP (via APIM)"
     }
     ```

9. **Create `infra/policies/authorize.xml`** — Consent initiation policy:
   - Inbound: Build the Entra ID authorization URL:
     - `client_id={apim-app-client-id}`
     - `response_type=code`
     - `redirect_uri=https://{apim-gateway-url}/callback`
     - `scope=499b84ac-1321-427f-aa17-267ca6975798/user_impersonation openid profile`
     - `prompt=consent` (force consent screen so user explicitly grants ADO delegation)
     - `state={random GUID for CSRF protection}`
   - `return-response` with 302 redirect to the constructed Entra authorize URL

10. **Create `infra/policies/callback.xml`** — Consent callback policy:
    - Inbound: Extract `code` query parameter
    - `authentication-managed-identity` to get MI token for `api://AzureADTokenExchange`
    - `send-request` to `https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token`:
      - `grant_type=authorization_code`
      - `client_id={apim-app-client-id}`
      - `code={authorization_code}`
      - `redirect_uri=https://{apim-gateway-url}/callback`
      - `client_assertion={MI token}`
      - `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`
    - On success: `return-response` with 200 OK, HTML body: "Consent granted successfully. You can close this window and retry your MCP request."
    - On error: `return-response` with 400 and error JSON

### Phase 5: Post-Provision Setup

11. **Create `hooks/postprovision.ps1`** — AZD post-provision hook:
    - Reads AZD environment outputs (app object ID, MI object ID, APIM gateway URL)
    - Set `identifierUris` on the app registration: `api://{appId}`
    - Add APIM callback URL to `web.redirectUris`: `https://{apim-gateway-url}/callback`
    - Create federated identity credential on the APIM app:
      ```json
      {
        "name": "apim-managed-identity",
        "issuer": "https://login.microsoftonline.com/{tenant-id}/v2.0",
        "subject": "{managed-identity-object-id}",
        "audiences": ["api://AzureADTokenExchange"]
      }
      ```
    - **No admin consent step** — user consent is handled at runtime via the `/authorize` + `/callback` flow

### Phase 6: Main Bicep Orchestration

12. **Create `infra/main.bicep`**:
    - Parameters: `location`, `environmentName`, `adoOrganization` (default: `'wegmans'`)
    - Module calls in dependency order: `managed-identity` → `entra-apps` → `apim`
    - Outputs: `apimGatewayUrl`, `apimAppClientId`, `apimAppObjectId`, `managedIdentityObjectId`

13. **Create `infra/main.parameters.json`**:
    - Binds `environmentName` to `${AZURE_ENV_NAME}`
    - Binds `location` to `${AZURE_LOCATION}`

### Phase 7: Testing Tools

14. **Create `tools/test-auth.ps1`** — PowerShell script:
    - Reads APIM URL and app client ID from AZD environment or prompts
    - Acquires user token for APIM audience using device code flow (`az login --scope api://{clientId}/user_impersonation`)
    - Validates PRM endpoint response
    - Sends MCP `initialize` request with Bearer token
    - Handles `consent_required` response by printing the `consent_uri`
    - Prints decoded token claims (aud, sub, scp, exp)

15. **Create `tools/test-mcp.http`** — REST Client `.http` file:
    - Variables: `@apimUrl`, `@tenantId`, `@clientId`, `@token` (set from test-auth.ps1 output)
    - Request 1: `GET {{apimUrl}}/.well-known/oauth-protected-resource` — verify PRM
    - Request 2: `GET {{apimUrl}}/authorize` — initiate consent (follow redirect in browser)
    - Request 3: `POST {{apimUrl}}/mcp` with `Authorization: Bearer {{token}}` — MCP `initialize`
    - Request 4: `POST {{apimUrl}}/mcp` with `Authorization: Bearer {{token}}` — MCP `tools/list`

16. **Create `.vscode/mcp.json`** — VS Code MCP configuration:
    ```json
    {
      "servers": {
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
| `tools/test-auth.ps1` | Acquires user token, validates PRM, sends MCP test requests |
| `tools/test-mcp.http` | REST Client file: PRM, authorize, MCP initialize, tools/list |
| `.vscode/mcp.json` | VS Code MCP server config pointing to APIM gateway |

## Verification

1. **`azd provision`** — Deploys all infrastructure; verify no errors in Bicep deployment
2. **Post-provision hook runs** — Verify federated credential created on app registration, `identifierUris` set, callback redirectUri added
3. **`GET https://{apim-url}/.well-known/oauth-protected-resource`** — Should return PRM JSON with correct `authorization_servers` and `scopes_supported`
4. **`tools/test-auth.ps1`** — Acquires user token; verify token `aud` claim matches APIM app client ID
5. **`POST https://{apim-url}/mcp`** without token — Should return 401 with `WWW-Authenticate: Bearer resource_metadata="..."` header
6. **`POST https://{apim-url}/mcp`** with valid Bearer token (first time, no consent) — Should return 403 with `{"error":"consent_required","consent_uri":"..."}`
7. **`GET https://{apim-url}/authorize`** — Should redirect (302) to Entra consent page; user grants ADO `user_impersonation` access
8. **Callback `GET https://{apim-url}/callback?code=...`** — Exchanges auth code, displays "Consent granted successfully" HTML page
9. **`POST https://{apim-url}/mcp`** with Bearer token (after consent) — Should proxy successfully to ADO Remote MCP, returning MCP `initialize` response
10. **VS Code agent mode** — Configure `.vscode/mcp.json`, open Copilot agent mode, verify ADO MCP tools list populates (projects, repos, work items, etc.)

## Decisions

| Decision | Rationale |
|----------|-----------|
| **Managed Identity (Federated Credential) over Client Secret** | User selected. No secret to rotate or leak. The user-assigned MI assigned to APIM acts as the client credential for OBO, using `api://AzureADTokenExchange` as the resource. |
| **Federated credential via post-provision hook** | Graph Bicep extension does not support `federatedIdentityCredentials` as a Bicep resource. The `hooks/postprovision.ps1` handles it via `az ad app federated-credential create`. |
| **APIM BasicV2 SKU** | Per user request. Supports all required policies: `validate-azure-ad-token`, `send-request`, `authentication-managed-identity`. |
| **Azure DevOps app ID `499b84ac-1321-427f-aa17-267ca6975798`** | Well-known first-party Microsoft app ID for Azure DevOps. OBO scope: `499b84ac-1321-427f-aa17-267ca6975798/user_impersonation`. |
| **PRM served from APIM** | The `/.well-known/oauth-protected-resource` endpoint uses a `return-response` policy with a static JSON body, keeping it decoupled from the MCP proxy logic. |
| **VS Code pre-authorized (`aebc6443-996d-45c2-90f0-388ff96faa56`)** | Pre-authorizing VS Code's app ID in `preAuthorizedApplications` allows VS Code to silently acquire tokens for the APIM audience without prompting the user for a separate APIM consent screen. |
| **User consent via `/authorize` + `/callback` (no admin consent)** | User does not have access to `az ad app permission admin-consent`. The OBO exchange to ADO will fail with `interaction_required` on first call. The MCP proxy policy detects this and returns 403 with a `consent_uri`. The `/authorize` APIM endpoint redirects the user to Entra with `prompt=consent` including the ADO scope. The `/callback` endpoint completes the consent. This is a one-time per-user operation. |
| **Subscription key disabled on all APIs** | MCP clients authenticate via OAuth Bearer token. Requiring an additional `Ocp-Apim-Subscription-Key` header would break standard MCP client flows. |

## Further Considerations

1. **Token caching**: The OBO exchange adds ~200–400ms latency per request. For production, add `cache-store-value` / `cache-lookup-value` policies keyed by `{user-sub}-{scope}` with TTL = token expiry minus a buffer. Not in initial scope.
2. **Rate limiting**: Consider `rate-limit-by-key` policy keyed by the user's `sub` claim from the validated JWT to prevent abuse. Not in initial scope.
3. **ADO MCP SSE streaming**: The ADO Remote MCP Server uses Streamable HTTP. APIM BasicV2 supports streaming; validate during testing that SSE chunks pass through correctly without buffering.
4. **State parameter CSRF**: The `/authorize` policy generates a random `state` GUID; the `/callback` policy should ideally validate it. Since APIM is stateless, this requires either a short-lived cache entry or accepting the limitation in a demo context.
