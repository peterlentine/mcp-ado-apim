param environmentName string
param location string

param apimAppClientId string
param managedIdentityClientId string
param managedIdentityResourceId string

param publisherEmail string = 'admin@contoso.com'
param publisherName string = 'MCP ADO Admin'

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────
var tenantId = '1318d57f-757b-45b3-b1b0-9b3c3842774f'
var adoOrg = 'wegmans'
var adoMcpBackendUrl = 'https://mcp.dev.azure.com/${adoOrg}'
var apimServiceName = 'apim-mcp-ado-${environmentName}'

// ── APIM Service ──────────────────────────────────────────────────────────────
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimServiceName
  location: location
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityResourceId}': {}
    }
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// ── Named Values ──────────────────────────────────────────────────────────────
// Referenced in policy XML as {{named-value-name}}

resource nvTenantId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'tenant-id'
  parent: apim
  properties: {
    displayName: 'tenant-id'
    value: tenantId
    secret: false
  }
}

resource nvApimClientId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'apim-app-client-id'
  parent: apim
  properties: {
    displayName: 'apim-app-client-id'
    value: apimAppClientId
    secret: false
  }
}

resource nvMiClientId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'managed-identity-client-id'
  parent: apim
  properties: {
    displayName: 'managed-identity-client-id'
    value: managedIdentityClientId
    secret: false
  }
}

resource nvAdoScope 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  name: 'ado-scope'
  parent: apim
  properties: {
    displayName: 'ado-scope'
    value: '499b84ac-1321-427f-aa17-267ca6975798/user_impersonation'
    secret: false
  }
}

// ── API 1: MCP Proxy ──────────────────────────────────────────────────────────
// Path: /mcp  →  https://{apim}.azure-api.net/mcp
// All operations share the API-level policy (mcp-proxy.xml).
// Policy is a placeholder in Phase 3; replaced in Phase 4 with OBO flow.
resource mcpApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  name: 'mcp-proxy'
  parent: apim
  properties: {
    displayName: 'Azure DevOps MCP Proxy'
    description: 'Proxies MCP Streamable HTTP requests to the Azure DevOps Remote MCP Server with OAuth 2.0 OBO token exchange.'
    path: 'mcp'
    protocols: ['https']
    subscriptionRequired: false
    // serviceUrl sets the backend for all operations on this API.
    // The OBO policy (Phase 4) replaces the Authorization header before forwarding.
    serviceUrl: adoMcpBackendUrl
    isCurrent: true
  }
}

// API-level policy — applies to all operations on the MCP API
resource mcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  name: 'policy'
  parent: mcpApi
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/mcp-proxy.xml')
  }
}

// POST /mcp — MCP JSON-RPC messages (initialize, tools/list, tools/call, etc.)
resource mcpPostOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: 'mcp-post'
  parent: mcpApi
  properties: {
    displayName: 'MCP Message (POST)'
    method: 'POST'
    urlTemplate: '/'
    description: 'Sends a JSON-RPC message to the MCP server.'
  }
}

// GET /mcp — MCP Server-Sent Events stream (Streamable HTTP transport)
resource mcpGetOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: 'mcp-get'
  parent: mcpApi
  properties: {
    displayName: 'MCP SSE Stream (GET)'
    method: 'GET'
    urlTemplate: '/'
    description: 'Opens a Server-Sent Events stream from the MCP server.'
  }
}

// DELETE /mcp — MCP session termination
resource mcpDeleteOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: 'mcp-delete'
  parent: mcpApi
  properties: {
    displayName: 'MCP Session Delete (DELETE)'
    method: 'DELETE'
    urlTemplate: '/'
    description: 'Terminates an MCP session.'
  }
}

// ── API 2: OAuth / Consent Endpoints ─────────────────────────────────────────
// Path: (empty)  →  https://{apim}.azure-api.net/
// Each operation has its own policy; no API-level policy needed.
//
//   GET /.well-known/oauth-protected-resource  — RFC 9728 PRM document
//   GET /authorize                              — initiates Entra consent flow
//   GET /callback                               — receives auth code, completes consent
resource oauthApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  name: 'oauth-consent'
  parent: apim
  properties: {
    displayName: 'OAuth Consent'
    description: 'RFC 9728 protected resource metadata and user consent flow endpoints.'
    path: ''
    protocols: ['https']
    subscriptionRequired: false
    isCurrent: true
  }
}

// ── GET /.well-known/oauth-protected-resource ─────────────────────────────────
resource prmOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: 'prm-get'
  parent: oauthApi
  properties: {
    displayName: 'Protected Resource Metadata'
    method: 'GET'
    urlTemplate: '/.well-known/oauth-protected-resource'
    description: 'Returns RFC 9728 protected resource metadata for MCP client auto-discovery.'
  }
}

resource prmOpPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  name: 'policy'
  parent: prmOp
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/prm-endpoint.xml')
  }
}

// ── GET /authorize ────────────────────────────────────────────────────────────
resource authorizeOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: 'oauth-authorize'
  parent: oauthApi
  properties: {
    displayName: 'Authorize (consent initiation)'
    method: 'GET'
    urlTemplate: '/authorize'
    description: 'Redirects the user to Entra ID to grant delegated consent for Azure DevOps.'
  }
}

resource authorizeOpPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  name: 'policy'
  parent: authorizeOp
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/authorize.xml')
  }
}

// ── GET /callback ─────────────────────────────────────────────────────────────
resource callbackOp 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  name: 'oauth-callback'
  parent: oauthApi
  properties: {
    displayName: 'Callback (consent completion)'
    method: 'GET'
    urlTemplate: '/callback'
    description: 'Receives the authorization code from Entra ID after user consent and exchanges it for tokens.'
  }
}

resource callbackOpPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  name: 'policy'
  parent: callbackOp
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/callback.xml')
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────
output apimServiceName string = apim.name
output gatewayUrl string = 'https://${apimServiceName}.azure-api.net'
