# tools/test-auth.ps1
# ─────────────────────────────────────────────────────────────────────────────
# Demonstrates the full OAuth 2.0 On-Behalf-Of flow through APIM:
#
#   Step 1 — Fetch Protected Resource Metadata (RFC 9728)
#             GET /.well-known/oauth-protected-resource
#   Step 2 — Acquire a token for the APIM Entra app using device code flow
#             (browser-less; user opens a URL and enters a short code)
#   Step 3 — Call the MCP /initialize endpoint with the Bearer token
#             Expect: 200 OR 403 consent_required (if consent not yet granted)
#   Step 4 — If consent needed, open the consent URL in the browser
#   Step 5 — After consent, retry the MCP call → expect 200
#
# Prerequisites:
#   • Azure CLI installed and signed in (`az login`)
#   • PowerShell 7+
#
# ─────────────────────────────────────────────────────────────────────────────

param(
    [string] $GatewayUrl      = "https://apim-mcp-ado-mcp-ado.azure-api.net",
    [string] $ApimAppClientId = "355d2574-1ed9-4fa3-9197-8de6242f8412",
    [string] $TenantId        = "1318d57f-757b-45b3-b1b0-9b3c3842774f"
)

$ErrorActionPreference = "Continue"

$ApimScope    = "api://$ApimAppClientId/user_impersonation"
$TokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$PrmUrl       = "$GatewayUrl/.well-known/oauth-protected-resource"
$McpUrl       = "$GatewayUrl/mcp"

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  APIM MCP / ADO OBO Flow — Authentication Test"          -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ─── Step 1: Protected Resource Metadata ──────────────────────────────────────
Write-Host "Step 1  GET $PrmUrl" -ForegroundColor Yellow
try {
    $prm = Invoke-RestMethod $PrmUrl
    Write-Host "  resource              : $($prm.resource)"
    Write-Host "  authorization_servers : $($prm.authorization_servers -join ', ')"
    Write-Host "  scopes_supported      : $($prm.scopes_supported -join ', ')"
    Write-Host "  bearer_methods_supported: $($prm.bearer_methods_supported -join ', ')"
} catch {
    Write-Warning "PRM request failed: $_"
}
Write-Host ""

# ─── Step 2: Device code flow — acquire APIM token ────────────────────────────
Write-Host "Step 2  Acquiring token via device code flow ..." -ForegroundColor Yellow
Write-Host "  Scope : $ApimScope"
Write-Host ""

$deviceCodeBody = "client_id=$ApimAppClientId" `
    + "&scope=" + [Uri]::EscapeDataString("$ApimScope openid profile") `
    + "&response_type=token"

$deviceCodeResponse = Invoke-RestMethod `
    -Method POST `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -ContentType "application/x-www-form-urlencoded" `
    -Body "client_id=$ApimAppClientId&scope=$([Uri]::EscapeDataString("$ApimScope openid profile"))"

Write-Host "  ┌──────────────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │  Open this URL in a browser:"                          -ForegroundColor Cyan
Write-Host "  │    $($deviceCodeResponse.verification_uri)"            -ForegroundColor White
Write-Host "  │"                                                        -ForegroundColor Cyan
Write-Host "  │  Enter this code: $($deviceCodeResponse.user_code)"    -ForegroundColor White
Write-Host "  └──────────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

$pollInterval = [int]($deviceCodeResponse.interval ?? 5)
$expiresIn    = [int]($deviceCodeResponse.expires_in ?? 900)
$deadline     = (Get-Date).AddSeconds($expiresIn)
$accessToken  = $null

Write-Host "  Polling for authentication ..." -ForegroundColor DarkGray
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $pollInterval
    try {
        $tokenResponse = Invoke-RestMethod `
            -Method POST `
            -Uri $TokenEndpoint `
            -ContentType "application/x-www-form-urlencoded" `
            -Body ("client_id=$ApimAppClientId" `
                 + "&grant_type=urn:ietf:params:oauth:grant-type:device_code" `
                 + "&device_code=$($deviceCodeResponse.device_code)")
        $accessToken = $tokenResponse.access_token
        Write-Host "  Token acquired." -ForegroundColor Green
        break
    } catch {
        $body = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($body.error -eq "authorization_pending") {
            Write-Host "  . " -NoNewline -ForegroundColor DarkGray
            continue
        } elseif ($body.error -eq "slow_down") {
            $pollInterval++
            continue
        } else {
            Write-Warning "Token poll failed: $($body.error) — $($body.error_description)"
            break
        }
    }
}

if (-not $accessToken) {
    Write-Error "Failed to acquire access token."
    exit 1
}

# Decode and show token claims
$tokenParts   = $accessToken.Split('.')
$claimsBase64 = $tokenParts[1].Replace('-', '+').Replace('_', '/')
switch ($claimsBase64.Length % 4) {
    2 { $claimsBase64 += "==" }
    3 { $claimsBase64 += "=" }
}
$claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($claimsBase64)) | ConvertFrom-Json
Write-Host ""
Write-Host "  Token claims:"
Write-Host "    aud : $($claims.aud)"
Write-Host "    iss : $($claims.iss)"
Write-Host "    upn : $($claims.upn ?? $claims.preferred_username)"
Write-Host "    exp : $(([DateTimeOffset]::FromUnixTimeSeconds($claims.exp)).LocalDateTime)"
Write-Host ""

# ─── Step 3: Call MCP endpoint ────────────────────────────────────────────────
Write-Host "Step 3  POST $McpUrl  (MCP initialize)" -ForegroundColor Yellow
$mcpBody = '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-auth.ps1","version":"1.0"}}}'

try {
    $mcpResponse = Invoke-WebRequest `
        -Method POST `
        -Uri $McpUrl `
        -Headers @{ Authorization = "Bearer $accessToken" } `
        -ContentType "application/json" `
        -Body $mcpBody `
        -ErrorAction Stop

    Write-Host "  Status : $($mcpResponse.StatusCode)" -ForegroundColor Green
    $mcpBody = $mcpResponse.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($mcpBody) {
        Write-Host "  MCP serverInfo: $($mcpBody.result.serverInfo | ConvertTo-Json -Compress)" -ForegroundColor Green
    }
} catch {
    $resp    = $_.Exception.Response
    $status  = [int]$resp.StatusCode
    $wwwAuth = $resp.Headers["WWW-Authenticate"]
    $bodyStr = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd()
    $bodyObj = $bodyStr | ConvertFrom-Json -ErrorAction SilentlyContinue

    Write-Host "  Status : $status" -ForegroundColor $(if ($status -eq 403) { "Yellow" } else { "Red" })
    if ($wwwAuth) { Write-Host "  WWW-Authenticate : $wwwAuth" -ForegroundColor DarkGray }

    if ($status -eq 403 -and $bodyObj.error -eq "consent_required") {
        Write-Host ""
        Write-Host "  ── Consent required ────────────────────────────────────" -ForegroundColor Yellow
        Write-Host "  The OBO exchange failed because the user hasn't granted"
        Write-Host "  consent for the APIM app to access Azure DevOps."
        Write-Host ""
        Write-Host "  ACTION: Open the consent URL in a browser:"
        Write-Host "    $($bodyObj.consent_uri)" -ForegroundColor White
        Write-Host ""

        # Optionally open consent URL automatically
        $openBrowser = Read-Host "  Open consent URL in default browser now? [Y/n]"
        if ($openBrowser -ne 'n' -and $openBrowser -ne 'N') {
            Start-Process $bodyObj.consent_uri
            Write-Host "  Browser opened. After granting consent, press Enter to retry."
            $null = Read-Host
        }

        # ─── Step 5: Retry after consent ──────────────────────────────────────
        Write-Host ""
        Write-Host "Step 5  POST $McpUrl  (retry after consent)" -ForegroundColor Yellow
        try {
            $retryResponse = Invoke-WebRequest `
                -Method POST `
                -Uri $McpUrl `
                -Headers @{ Authorization = "Bearer $accessToken" } `
                -ContentType "application/json" `
                -Body $mcpBody `
                -ErrorAction Stop

            Write-Host "  Status : $($retryResponse.StatusCode)" -ForegroundColor Green
            $retryBody = $retryResponse.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($retryBody) {
                Write-Host "  MCP serverInfo: $($retryBody.result.serverInfo | ConvertTo-Json -Compress)" -ForegroundColor Green
            }
        } catch {
            $r2 = $_.Exception.Response
            Write-Host "  Status : $([int]$r2.StatusCode)" -ForegroundColor Red
            Write-Host "  Body   : $([System.IO.StreamReader]::new($r2.GetResponseStream()).ReadToEnd())"
            Write-Host ""
            Write-Host "  NOTE: If still failing, the original token may have expired." -ForegroundColor DarkGray
            Write-Host "        Re-run this script to get a fresh token."               -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  Body   : $bodyStr"
    }
}

Write-Host ""
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Done." -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
