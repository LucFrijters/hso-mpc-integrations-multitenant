# Application startup script
# Runs once when the Function App host starts

# Import shared modules
$modulesPath = Join-Path $PSScriptRoot 'modules'
foreach ($module in Get-ChildItem -Path $modulesPath -Filter '*.psm1' -Recurse) {
    Import-Module $module.FullName -Force -ErrorAction Stop
    Write-Host "Imported module: $($module.BaseName)"
}

Disable-AzContextAutosave -Scope Process | Out-Null
if ($env:IDENTITY_ENDPOINT -or $env:MSI_ENDPOINT) {
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Write-Host 'Connected to Azure using the Function App managed identity'
}
else {
    Write-Host 'Managed identity endpoint not detected; using existing Az context if available'
}

Write-Host "HSO MPC Integration Function App initialized"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host "Worker runtime: $env:FUNCTIONS_WORKER_RUNTIME"
