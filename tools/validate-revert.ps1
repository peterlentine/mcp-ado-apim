$apim = "apim-ptw4lax6otj5i"
$rg   = "rg-mcp-ado"

# 1. mcp-proxy API removed?
az apim api show -g $rg -n $apim --api-id mcp-proxy 2>$null | Out-Null
Write-Host "mcp-proxy API removed: $($LASTEXITCODE -ne 0)"

# 2. ado-mcp-backend removed?
az apim backend show -g $rg -n $apim --backend-id ado-mcp-backend 2>$null | Out-Null
Write-Host "ado-mcp-backend removed: $($LASTEXITCODE -ne 0)"

# 3. PRM still works?
$prm = Invoke-WebRequest -Uri "https://$apim.azure-api.net/well-known/oauth-protected-resource" -SkipHttpErrorCheck -ErrorAction SilentlyContinue
Write-Host "PRM status: $($prm.StatusCode)"

# 4. Named values count?
$nv = az apim nv list -g $rg -n $apim --query "length(@)" -o tsv 2>&1
Write-Host "Named values count: $nv (expected 5)"
