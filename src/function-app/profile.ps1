# Application startup script
# Runs once when the Function App host starts

# Import shared modules
$modulesPath = Join-Path $PSScriptRoot 'modules'
foreach ($module in Get-ChildItem -Path $modulesPath -Filter '*.psm1' -Recurse) {
    Import-Module $module.FullName -Force -ErrorAction Stop
    Write-Host "Imported module: $($module.BaseName)"
}

Write-Host "HSO MPC Integration Function App initialized"
Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host "Worker runtime: $env:FUNCTIONS_WORKER_RUNTIME"
