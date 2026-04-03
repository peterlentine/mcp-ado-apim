extension microsoftGraphV1

@description('Environment name used to generate a stable, unique app registration name.')
param environmentName string

// Stable, deterministic GUID for the user_impersonation scope.
// Used by postprovision.ps1 to create the scope and preAuthorizedApplications idempotently,
// since Graph API rejects updating enabled scopes via PUT (even with identical values).
var uniqueName = 'apim-mcp-ado-proxy-${environmentName}'
var userImpersonationScopeId = guid(uniqueName, 'user_impersonation')

// APIM MCP Proxy app registration.
// oauth2PermissionScopes and preAuthorizedApplications are set in postprovision.ps1
// to avoid the Graph API "cannot update enabled scope" restriction on re-deployments.
resource apimApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: uniqueName
  displayName: 'APIM MCP ADO Proxy'
  signInAudience: 'AzureADMyOrg'

  api: {
    requestedAccessTokenVersion: 2
  }

  // Require Azure DevOps user_impersonation (enables OBO exchange downstream)
  requiredResourceAccess: [
    {
      resourceAppId: '499b84ac-1321-427f-aa17-267ca6975798' // Azure DevOps first-party app
      resourceAccess: [
        {
          id: 'ee69721e-6c3a-468f-a9ec-302d16a4c599' // user_impersonation scope GUID
          type: 'Scope'
        }
      ]
    }
  ]

  web: {
    // Testing redirect URI — callback URI added by postprovision.ps1 in Phase 5
    redirectUris: [
      'https://login.microsoftonline.com/common/oauth2/nativeclient'
    ]
  }
}

// Service principal — required for token issuance and consent tracking
resource apimSp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: apimApp.appId
}

output appId string = apimApp.appId
output objectId string = apimApp.id
output userImpersonationScopeId string = userImpersonationScopeId
