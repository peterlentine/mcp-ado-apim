# Revert: Remove MCP Proxy API

**Purpose**: Remove the custom MCP Proxy API, backend, and policy created in the original Phase 5. These are being replaced by the APIM MCP Servers feature.

**Prerequisite**: Phases 1–4 remain intact and unaffected. Only Phase 5 artifacts are removed.

---

## Steps

### 1. Update `infra/modules/apim.bicep`

Remove the following resources:

- `adoBackend` — `Microsoft.ApiManagement/service/backends` (`ado-mcp-backend`)
- `mcpApi` — `Microsoft.ApiManagement/service/apis` (`mcp-proxy`)
- `mcpPostOperation` — `POST /*` operation under `mcp-proxy`
- `mcpGetOperation` — `GET /*` operation under `mcp-proxy`
- `mcpDeleteOperation` — `DELETE /*` operation under `mcp-proxy`
- `mcpApiPolicy` — API-level policy referencing `mcp-proxy.xml`

Keep everything else (APIM instance, named values, PRM API, PRM operation, PRM policy).

### 2. Delete files

- `infra/policies/mcp-proxy.xml` — OBO policy will be applied at MCP Server scope instead
- `tools/test-phase5.ps1` — Validation script for the old approach

### 3. Build and provision

```powershell
az bicep build --file infra/main.bicep
azd provision
```

### 4. Validate

| Check | Expected |
|-------|----------|
| `az bicep build --file infra/main.bicep` | Zero errors |
| `azd provision` | Succeeds |
| `az apim api show -g rg-mcp-ado -n apim-ptw4lax6otj5i --api-id mcp-proxy` | 404 Not Found (removed) |
| `az apim backend show -g rg-mcp-ado -n apim-ptw4lax6otj5i --backend-id ado-mcp-backend` | 404 Not Found (removed) |
| `GET /well-known/oauth-protected-resource` | 200 JSON (PRM unaffected) |
| `az apim nv list -g rg-mcp-ado -n apim-ptw4lax6otj5i --query "[].displayName"` | All 5 named values still present |
