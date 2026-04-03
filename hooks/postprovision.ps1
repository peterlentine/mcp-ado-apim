# hooks/postprovision.ps1 — Phase 5: Entra app post-configuration
#
# Run automatically by `azd provision` after the Bicep deployment completes.
#
# What this hook does:
#   1. Sets identifierUris on the Entra app  → enables api:// audience in tokens
#   2. Adds the OAuth callback redirect URI  → required for user consent flow
#   3. Creates a federated identity credential trusting the user-assigned MI
#      → allows APIM to use the MI as client_assertion in OBO exchanges
#         (no client secret required)
#
param()
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ─── Values injected by azd from Bicep outputs ────────────────────────────────
$appObjectId   = $env:APIM_APP_OBJECT_ID
$appClientId   = $env:APIM_APP_CLIENT_ID
$gatewayUrl    = $env:APIM_GATEWAY_URL
$miPrincipalId = $env:MANAGED_IDENTITY_PRINCIPAL_ID
$tenantId      = $env:AZURE_TENANT_ID

if (-not $appObjectId -or -not $appClientId -or -not $gatewayUrl -or
    -not $miPrincipalId -or -not $tenantId) {
    Write-Error "Required environment variables are missing. Ensure azd provision completed successfully."
    exit 1
}

Write-Host ""
Write-Host "=== Post-Provision Hook ===" -ForegroundColor Cyan
Write-Host "  App Object ID   : $appObjectId"
Write-Host "  App Client ID   : $appClientId"
Write-Host "  Gateway URL     : $gatewayUrl"
Write-Host "  MI Principal ID : $miPrincipalId"
Write-Host "  Tenant ID       : $tenantId"
Write-Host ""

# ─── Step 1: Set identifierUris ───────────────────────────────────────────────
$apiUri = "api://$appClientId"
Write-Host "Step 1: Setting identifierUris = ['$apiUri'] ..." -ForegroundColor Yellow

az ad app update --id $appObjectId --identifier-uris $apiUri
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to set identifierUris."; exit 1 }
Write-Host "  OK" -ForegroundColor Green

# ─── Step 2: Add OAuth callback redirect URI ──────────────────────────────────
$callbackUri = ($gatewayUrl.TrimEnd('/')) + "/callback"
Write-Host "Step 2: Ensuring redirect URI '$callbackUri' is registered ..." -ForegroundColor Yellow

$currentApp       = az ad app show --id $appObjectId | ConvertFrom-Json
$currentRedirects = @($currentApp.web.redirectUris) | Where-Object { $_ }

if ($currentRedirects -contains $callbackUri) {
    Write-Host "  Already present — skipping." -ForegroundColor Green
} else {
    $newRedirects = @($currentRedirects) + $callbackUri
    az ad app update --id $appObjectId --web-redirect-uris @newRedirects
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to add redirect URI."; exit 1 }
    Write-Host "  OK" -ForegroundColor Green
}

# ─── Step 3: Create federated identity credential ─────────────────────────────
# Trusts ID tokens issued by Entra for the managed identity principal,
# allowing the MI to authenticate as the APIM Entra app in OBO requests.
$ficName = "apim-mi-federation"
Write-Host "Step 3: Ensuring federated identity credential '$ficName' exists ..." -ForegroundColor Yellow

$existingFics = az ad app federated-credential list --id $appObjectId | ConvertFrom-Json
if ($existingFics | Where-Object { $_.name -eq $ficName }) {
    Write-Host "  Already present — skipping." -ForegroundColor Green
} else {
    $ficParams = @{
        name        = $ficName
        issuer      = "https://login.microsoftonline.com/$tenantId/v2.0"
        subject     = $miPrincipalId
        audiences   = @("api://AzureADTokenExchange")
        description = "Allows the APIM user-assigned MI to perform OBO exchanges as the APIM Entra app (no client secret)"
    } | ConvertTo-Json -Compress

    az ad app federated-credential create --id $appObjectId --parameters $ficParams
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create federated identity credential."; exit 1 }
    Write-Host "  OK" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Post-Provision Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Grant consent : $gatewayUrl/authorize" -ForegroundColor White
Write-Host "  2. Run test tool : .\tools\test-auth.ps1" -ForegroundColor White
Write-Host ""
