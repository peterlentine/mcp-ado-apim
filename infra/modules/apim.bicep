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
// Outputs
// -----------------------------------------------------------------
output gatewayUrl string = apim.properties.gatewayUrl
output apimName string = apim.name
