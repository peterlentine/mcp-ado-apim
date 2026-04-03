@description('APIM instance name.')
param name string

@description('Azure location.')
param location string

@description('Resource ID of the user-assigned managed identity.')
param managedIdentityId string

@description('Client ID of the user-assigned managed identity.')
param managedIdentityClientId string

@description('Entra tenant ID.')
param tenantId string

@description('APIM MCP Proxy app client ID.')
param apimAppClientId string

@description('Azure DevOps organization name.')
param adoOrganization string

@description('Tags to apply to resources.')
param tags object = {}

// -----------------------------------------------------------------
// APIM instance — BasicV2, user-assigned managed identity
// -----------------------------------------------------------------
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    publisherEmail: 'admin@example.com'
    publisherName: 'MCP ADO Proxy'
  }
}

// -----------------------------------------------------------------
// Named values
// -----------------------------------------------------------------
resource nvTenantId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'tenant-id'
  properties: {
    displayName: 'tenant-id'
    value: tenantId
    secret: false
  }
}

resource nvApimAppClientId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'apim-app-client-id'
  properties: {
    displayName: 'apim-app-client-id'
    value: apimAppClientId
    secret: false
  }
}

resource nvMiClientId 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'managed-identity-client-id'
  properties: {
    displayName: 'managed-identity-client-id'
    value: managedIdentityClientId
    secret: false
  }
}

resource nvAdoOrg 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-org'
  properties: {
    displayName: 'ado-org'
    value: adoOrganization
    secret: false
  }
}

resource nvAdoScope 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'ado-scope'
  properties: {
    displayName: 'ado-scope'
    value: '499b84ac-1321-427f-aa17-267ca6975798/user_impersonation'
    secret: false
  }
}

// -----------------------------------------------------------------
// PRM API — GET /.well-known/oauth-protected-resource
// -----------------------------------------------------------------
resource prmApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'prm'
  properties: {
    displayName: 'Protected Resource Metadata'
    // APIM rejects paths starting with '.', so we use 'well-known' and adjust all metadata URLs accordingly.
    path: 'well-known'
    serviceUrl: null
    protocols: ['https']
    subscriptionRequired: false
  }
}

resource prmOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: prmApi
  name: 'get-oauth-protected-resource'
  properties: {
    displayName: 'Get OAuth Protected Resource Metadata'
    method: 'GET'
    urlTemplate: '/oauth-protected-resource'
  }
}

resource prmPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: prmOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/prm-endpoint.xml')
  }
  dependsOn: [nvTenantId, nvApimAppClientId]
}

// -----------------------------------------------------------------
// Phase 5: ADO MCP Server — Backend + MCP API + OBO Policy
// Uses 2024-06-01-preview which supports type: 'mcp'
// -----------------------------------------------------------------
resource adoMcpBackend 'Microsoft.ApiManagement/service/backends@2024-06-01-preview' = {
  parent: apim
  name: 'ado-mcp-backend'
  properties: {
    description: 'Azure DevOps Remote MCP Server (${adoOrganization} org)'
    url: 'https://mcp.dev.azure.com/${adoOrganization}'
    protocol: 'http'
  }
}

resource adoMcpApi 'Microsoft.ApiManagement/service/apis@2024-06-01-preview' = {
  parent: apim
  name: 'ado-mcp'
  properties: {
    type: 'mcp'
    displayName: 'Azure DevOps MCP'
    description: 'Azure DevOps Remote MCP Server (${adoOrganization} org)'
    subscriptionRequired: false
    // path 'ado/mcp' → gateway endpoint: https://<apim>/ado/mcp
    path: 'ado/mcp'
    protocols: [
      'https'
    ]
    backendId: adoMcpBackend.name
  }
  dependsOn: [nvTenantId, nvApimAppClientId, nvMiClientId, nvAdoOrg, nvAdoScope]
}

resource adoMcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-06-01-preview' = {
  parent: adoMcpApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/mcp-server-obo.xml')
  }
}

// -----------------------------------------------------------------
// Phase 6: Consent API — GET /authorize + GET /callback
// Path '' (root) so the operations land at /authorize and /callback
// -----------------------------------------------------------------
resource consentApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'consent'
  properties: {
    displayName: 'Consent Flow'
    path: ''
    protocols: ['https']
    subscriptionRequired: false
    serviceUrl: null
  }
}

resource authorizeOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: consentApi
  name: 'get-authorize'
  properties: {
    displayName: 'Initiate Consent'
    method: 'GET'
    urlTemplate: '/authorize'
  }
}

resource authorizePolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: authorizeOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/authorize.xml')
  }
  dependsOn: [nvTenantId, nvApimAppClientId]
}

resource callbackOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: consentApi
  name: 'get-callback'
  properties: {
    displayName: 'Consent Callback'
    method: 'GET'
    urlTemplate: '/callback'
  }
}

resource callbackPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: callbackOperation
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/callback.xml')
  }
  dependsOn: [nvTenantId, nvApimAppClientId, nvMiClientId]
}

// -----------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------
output gatewayUrl string = apim.properties.gatewayUrl
output apimName string = apim.name
output adoMcpPath string = adoMcpApi.properties.path
