#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Post-provision hook for mcp-ado-apim.
  Phase 3: identifierUris, user_impersonation scope, preAuthorizedApplications, federated credential.
  Phase 5: adds APIM callback redirectUri (runs again after APIM is deployed).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GraphPatch {
    param([string]$Uri, [object]$Body)
    $tmp = [System.IO.Path]::GetTempFileName() + ".json"
    $Body | ConvertTo-Json -Depth 10 -Compress | Set-Content -Path $tmp -Encoding UTF8 -NoNewline
    try {
        az rest --method PATCH --uri $Uri --headers "Content-Type=application/json" --body "@$tmp" 2>&1
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
}

Write-Host "==> postprovision.ps1 starting" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Read AZD outputs
# ---------------------------------------------------------------------------
$envValues    = azd env get-values --output json | ConvertFrom-Json -AsHashtable
$objectId     = $envValues['APIM_APP_OBJECT_ID']
$appId        = $envValues['APIM_APP_CLIENT_ID']
$tenantId     = $envValues['AZURE_TENANT_ID']
$miObjectId   = $envValues['MANAGED_IDENTITY_OBJECT_ID']
$scopeId      = $envValues['APIM_APP_SCOPE_ID']
$apimUrl      = $envValues.ContainsKey('APIM_GATEWAY_URL') ? $envValues['APIM_GATEWAY_URL'] : $null

if (-not $objectId -or -not $appId -or -not $tenantId -or -not $miObjectId -or -not $scopeId) {
    Write-Error "Missing required AZD output values. Ensure azd provision completed successfully."
    exit 1
}

Write-Host "  App Object ID : $objectId"
Write-Host "  App Client ID : $appId"
Write-Host "  Tenant ID     : $tenantId"
Write-Host "  MI Object ID  : $miObjectId"
Write-Host "  Scope ID      : $scopeId"

# ---------------------------------------------------------------------------
# 1. Set identifierUris
# ---------------------------------------------------------------------------
Write-Host "`n==> Setting identifierUris to api://$appId" -ForegroundColor Cyan
az ad app update --id $objectId --identifier-uris "api://$appId" 2>&1 | Write-Host
Write-Host "  Done."

# ---------------------------------------------------------------------------
# 2. Add user_impersonation oauth2PermissionScope (idempotent)
# ---------------------------------------------------------------------------
Write-Host "`n==> Setting oauth2PermissionScopes" -ForegroundColor Cyan

$existing = @(az ad app show --id $objectId --query "api.oauth2PermissionScopes" -o json | ConvertFrom-Json)
$hasScope = $existing | Where-Object { $_.id -eq $scopeId }

if ($hasScope) {
    Write-Host "  Scope $scopeId already exists — skipping."
} else {
    $body = @{
        api = @{
            oauth2PermissionScopes = @(
                @{
                    id                      = $scopeId
                    adminConsentDescription = "Allow the application to access APIM MCP ADO Proxy on behalf of the signed-in user."
                    adminConsentDisplayName = "Access APIM MCP ADO Proxy"
                    userConsentDescription  = "Allow the application to access APIM MCP ADO Proxy on your behalf."
                    userConsentDisplayName  = "Access APIM MCP ADO Proxy"
                    value                   = "user_impersonation"
                    isEnabled               = $true
                    type                    = "User"
                }
            )
        }
    }
    Invoke-GraphPatch -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Body $body | Write-Host
    Write-Host "  Scope created."
}

# ---------------------------------------------------------------------------
# 3. Add preAuthorizedApplications for VS Code + Azure CLI (idempotent)
# ---------------------------------------------------------------------------
Write-Host "`n==> Setting preAuthorizedApplications" -ForegroundColor Cyan

$requiredPreAuth = @(
    @{ appId = 'aebc6443-996d-45c2-90f0-388ff96faa56'; label = 'VS Code' }
    @{ appId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'; label = 'Azure CLI' }
)

$existingPreAuth = @(az ad app show --id $objectId --query "api.preAuthorizedApplications" -o json | ConvertFrom-Json)
$missing = $requiredPreAuth | Where-Object { $ea = $existingPreAuth; $id = $_.appId; -not ($ea | Where-Object { $_.appId -eq $id }) }

if (-not $missing) {
    Write-Host "  All pre-authorizations already exist — skipping."
} else {
    $missing | ForEach-Object { Write-Host "  Adding pre-authorization for $($_.label) ($($_.appId))" }
    # Build full merged array (existing + new) to avoid overwriting
    $merged = @($existingPreAuth | ForEach-Object { @{ appId = $_.appId; delegatedPermissionIds = @($scopeId) } })
    $missing | ForEach-Object { $merged += @{ appId = $_.appId; delegatedPermissionIds = @($scopeId) } }
    $body = @{ api = @{ preAuthorizedApplications = $merged } }
    Invoke-GraphPatch -Uri "https://graph.microsoft.com/v1.0/applications/$objectId" -Body $body | Write-Host
    Write-Host "  Pre-authorizations updated."
}

# ---------------------------------------------------------------------------
# 4. Create federated identity credential (idempotent)
# ---------------------------------------------------------------------------
Write-Host "`n==> Creating federated identity credential" -ForegroundColor Cyan

$credName      = 'apim-managed-identity'
$existingCreds = @(az ad app federated-credential list --id $objectId --query "[?name=='$credName']" -o json | ConvertFrom-Json)

if ($existingCreds.Count -gt 0) {
    Write-Host "  Federated credential '$credName' already exists — skipping."
} else {
    $tmp = [System.IO.Path]::GetTempFileName() + ".json"
    @{
        name      = $credName
        issuer    = "https://login.microsoftonline.com/$tenantId/v2.0"
        subject   = $miObjectId
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding UTF8 -NoNewline
    try {
        az ad app federated-credential create --id $objectId --parameters "@$tmp" 2>&1 | Write-Host
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    Write-Host "  Federated credential created."
}

# ---------------------------------------------------------------------------
# 5. Add APIM callback redirectUri (Phase 5 — only if APIM is deployed)
# ---------------------------------------------------------------------------
if ($apimUrl) {
    # gatewayUrl from ARM already includes https:// scheme — use as-is
    $callbackUri = "$apimUrl/callback"
    if (-not $apimUrl.StartsWith("https://")) {
        $callbackUri = "https://$apimUrl/callback"
    }
    Write-Host "`n==> Adding callback redirectUri: $callbackUri" -ForegroundColor Cyan

    $existingUris = @(az ad app show --id $objectId --query "web.redirectUris" -o json | ConvertFrom-Json)
    if ($existingUris -contains $callbackUri) {
        Write-Host "  Callback URI already present — skipping."
    } else {
        $allUris = @($existingUris) + $callbackUri
        az ad app update --id $objectId --web-redirect-uris @allUris 2>&1 | Write-Host
        Write-Host "  Callback URI added."
    }
} else {
    Write-Host "`n  APIM_GATEWAY_URL not yet set — skipping callback redirectUri (Phase 5)." -ForegroundColor Yellow
}

Write-Host "`n==> postprovision.ps1 complete." -ForegroundColor Green
