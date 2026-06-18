param($InputData)

<#
.SYNOPSIS
    Activity function: loads the collection registry definition.
    Returns the structured registry: SecurityScoreEndpoints, InsightsCatalog, InsightsReports.
#>

$correlationId = $InputData
Write-Host "[$correlationId] LoadEndpointRegistry: loading registry definitions"

$registryPath = Join-Path $PSScriptRoot '..' 'modules' 'EndpointRegistry.psd1'
$registry = Import-PowerShellDataFile -Path $registryPath

$result = @{
    SecurityScoreEndpoints = @($registry.SecurityScoreEndpoints)
    InsightsCatalog        = @($registry.InsightsCatalog)
    InsightsReports        = @($registry.InsightsReports)
}

Write-Host "[$correlationId] LoadEndpointRegistry: $($result.SecurityScoreEndpoints.Count) security endpoints, $($result.InsightsCatalog.Count) catalog endpoints, $($result.InsightsReports.Count) report definitions"

return $result
