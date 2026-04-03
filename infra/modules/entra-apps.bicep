extension microsoftGraphV1

param environmentName string

// ─────────────────────────────────────────────────────────────────────────────
// Well-known IDs
// ─────────────────────────────────────────────────────────────────────────────

// VS Code app that will be pre-authorized to silently acquire APIM tokens
var vsCodeAppId = 'aebc6443-996d-45c2-90f0-388ff96faa56'

// Azure DevOps first-party service app
var adoAppId = '499b84ac-1321-427f-aa17-267ca6975798'

// Delegated scope GUID for Azure DevOps user_impersonation.
// Verify with: az ad sp show --id 499b84ac-1321-427f-aa17-267ca6975798
//              --query "oauth2PermissionScopes[?value=='user_impersonation'].id" -o tsv
var adoUserImpersonationScopeId = 'ee69721e-6c3a-468f-a9ec-302d16a4c599'

// ─────────────────────────────────────────────────────────────────────────────
// Stable scope GUID for the user_impersonation scope THIS APP exposes.
// Must remain constant across re-deployments; changing it invalidates existing
// consent grants and breaks token issuance.
// ─────────────────────────────────────────────────────────────────────────────
var userImpersonationScopeId = 'b3e1e2d3-4f5a-6b7c-8d9e-0f1a2b3c4d5e'

// ─────────────────────────────────────────────────────────────────────────────
// App Registration — APIM MCP ADO Proxy
// Acts as the OAuth 2.0 resource that MCP clients (e.g. VS Code) target.
// APIM validates tokens issued for this app, then exchanges them via OBO for
// an Azure DevOps access token.
// ─────────────────────────────────────────────────────────────────────────────
resource apimApp 'Microsoft.Graph/applications@v1.0' = {
  displayName: 'APIM MCP ADO Proxy (${environmentName})'
  uniqueName: 'apim-mcp-ado-proxy-${environmentName}'
  signInAudience: 'AzureADMyOrg'

  api: {
    // Issue v2 tokens so aud claim is the client GUID (not a legacy URI)
    requestedAccessTokenVersion: 2

    // Delegated scope this app exposes to callers
    oauth2PermissionScopes: [
      {
        id: userImpersonationScopeId
        value: 'user_impersonation'
        type: 'User'
        isEnabled: true
        adminConsentDisplayName: 'Access Azure DevOps MCP via APIM'
        adminConsentDescription: 'Allows the app to access the Azure DevOps MCP gateway through APIM on behalf of the signed-in user.'
        userConsentDisplayName: 'Access Azure DevOps MCP via APIM'
        userConsentDescription: 'Allows this app to access the Azure DevOps MCP gateway through APIM on your behalf.'
      }
    ]

    // Pre-authorize VS Code so it can silently acquire tokens for this app
    // without triggering a separate APIM consent prompt for the user
    preAuthorizedApplications: [
      {
        appId: vsCodeAppId
        delegatedPermissionIds: [userImpersonationScopeId]
      }
    ]
  }

  // Declare the downstream permission this app needs to perform the OBO exchange.
  // User consent for this permission is collected at runtime via /authorize + /callback.
  requiredResourceAccess: [
    {
      resourceAppId: adoAppId
      resourceAccess: [
        {
          id: adoUserImpersonationScopeId
          type: 'Scope'
        }
      ]
    }
  ]

  // Redirect URIs:
  //   - nativeclient: used by test-auth.ps1 device code + az cli flows
  //   - /callback URI added by hooks/postprovision.ps1 once APIM gateway URL is known
  web: {
    redirectUris: [
      'https://login.microsoftonline.com/common/oauth2/nativeclient'
    ]
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service Principal for the app registration
// Required so Entra can issue tokens and consent can be recorded against it
// ─────────────────────────────────────────────────────────────────────────────
resource apimServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: apimApp.appId
}

// ─────────────────────────────────────────────────────────────────────────────
// Outputs consumed by apim.bicep and hooks/postprovision.ps1
// ─────────────────────────────────────────────────────────────────────────────
output appId string = apimApp.appId
output appObjectId string = apimApp.id
output servicePrincipalId string = apimServicePrincipal.id
output userImpersonationScopeId string = userImpersonationScopeId
