$token = (az account get-access-token --resource "api://36eb7a86-3565-4c53-b010-2d2dc98c5cc2" -o json | ConvertFrom-Json).accessToken
Write-Host "Token length: $($token.Length)"

# Test 1: no token -> 401
$r1 = Invoke-WebRequest -Uri "https://apim-ptw4lax6otj5i.azure-api.net/mcp" -Method POST -SkipHttpErrorCheck -ErrorAction SilentlyContinue
Write-Host "Test 1 (no token) Status: $($r1.StatusCode)"
Write-Host "  WWW-Authenticate: $($r1.Headers['WWW-Authenticate'])"

# Test 2: valid token -> 403 consent_required
$r2 = Invoke-WebRequest -Uri "https://apim-ptw4lax6otj5i.azure-api.net/mcp" -Method POST -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } -Body '{"jsonrpc":"2.0","method":"initialize","id":1}' -SkipHttpErrorCheck -ErrorAction SilentlyContinue
Write-Host "Test 2 (valid token) Status: $($r2.StatusCode)"
Write-Host "  Body: $($r2.Content)"
