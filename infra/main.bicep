targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment, used for resource naming.')
param environmentName string

@minLength(1)
@description('Primary Azure location for all resources.')
param location string

@description('Azure DevOps organization name. Passed to APIM module in Phase 4.')
param adoOrganization string = 'wegmans'

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var resourceGroupName = 'rg-${environmentName}'
var tags = {
  'azd-env-name': environmentName
}

// Resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// Managed Identity
module managedIdentity 'modules/managed-identity.bicep' = {
  name: 'managed-identity'
  scope: rg
  params: {
    name: 'id-${resourceToken}'
    location: location
    tags: tags
  }
}

// Outputs
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = subscription().tenantId
output RESOURCE_GROUP_NAME string = resourceGroupName
output MANAGED_IDENTITY_ID string = managedIdentity.outputs.id
output MANAGED_IDENTITY_OBJECT_ID string = managedIdentity.outputs.principalId
output MANAGED_IDENTITY_CLIENT_ID string = managedIdentity.outputs.clientId
output MANAGED_IDENTITY_NAME string = managedIdentity.outputs.name
