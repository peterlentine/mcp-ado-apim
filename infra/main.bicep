// ─────────────────────────────────────────────────────────────────────────────
// Main orchestration for mcp-ado-apim
// Deploys: user-assigned managed identity, Entra ID app registration, APIM
//
// Prerequisites for the deploying identity:
//   Azure:  Contributor on the target resource group
//   Entra:  Application.ReadWrite.OwnedBy (or Application.ReadWrite.All)
//           Required for the Microsoft Graph Bicep extension to create the
//           app registration in entra-apps.bicep
// ─────────────────────────────────────────────────────────────────────────────

param environmentName string
param location string = resourceGroup().location

// APIM publisher info — required by the resource provider, not user-facing
param publisherEmail string = 'admin@contoso.com'
param publisherName string = 'MCP ADO Admin'

var tags = {
  'azd-env-name': environmentName
  project: 'mcp-ado-apim'
}

// ── Managed Identity ─────────────────────────────────────────────────────────
// Must be created first; its clientId and principalId are referenced
// by both the Entra app federated credential (added post-provision) and APIM.
module managedIdentity 'modules/managed-identity.bicep' = {
  name: 'managed-identity'
  params: {
    environmentName: environmentName
    location: location
  }
}

// ── Entra ID App Registration ─────────────────────────────────────────────────
// Creates the APIM MCP ADO Proxy app + service principal via Graph Bicep.
// The appId output is passed to APIM as a Named Value so policies can
// reference it as {{apim-app-client-id}}.
module entraApps 'modules/entra-apps.bicep' = {
  name: 'entra-apps'
  params: {
    environmentName: environmentName
  }
}

// ── APIM ──────────────────────────────────────────────────────────────────────
// Depends implicitly on both modules above via parameter references.
module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    environmentName: environmentName
    location: location
    apimAppClientId: entraApps.outputs.appId
    managedIdentityClientId: managedIdentity.outputs.clientId
    managedIdentityResourceId: managedIdentity.outputs.resourceId
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Outputs
// AZD exports these as environment variables available to hooks and scripts.
// ─────────────────────────────────────────────────────────────────────────────
output APIM_GATEWAY_URL string = apim.outputs.gatewayUrl
output APIM_SERVICE_NAME string = apim.outputs.apimServiceName
output APIM_APP_CLIENT_ID string = entraApps.outputs.appId
output APIM_APP_OBJECT_ID string = entraApps.outputs.appObjectId
output MANAGED_IDENTITY_PRINCIPAL_ID string = managedIdentity.outputs.principalId
output MANAGED_IDENTITY_CLIENT_ID string = managedIdentity.outputs.clientId
