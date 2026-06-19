<#
.SYNOPSIS
    Blob Storage module for writing collected API data and metadata to Azure Blob Storage.
    Uses Managed Identity for authentication (no storage keys).
#>

function Get-SafeBlobPathSegment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Value
    )

    $safeValue = $Value -replace '[^a-zA-Z0-9\-]', '-'
    $safeValue = $safeValue.Trim('-').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($safeValue)) { return 'unknown' }
    return $safeValue
}


function Get-CollectionDataType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Endpoint
    )

    if ($Endpoint.ApiSurface -eq 'graph-beta' -or $Endpoint.Category -eq 'partner-security-score') {
        return 'security-score'
    }

    if ($Endpoint.ApiSurface -eq 'partner-insights') {
        return 'partner-insights-reports'
    }

    return Get-SafeBlobPathSegment -Value ($Endpoint.Category ?? $Endpoint.ApiSurface ?? 'other')
}


function Write-CollectionToBlob {
    <#
    .SYNOPSIS
        Writes collected API data and its metadata sidecar to Azure Blob Storage.
    .PARAMETER TenantId
        The CSP tenant ID.
    .PARAMETER TenantName
        Human-readable tenant display name.
    .PARAMETER Endpoint
        The endpoint definition object from the registry.
    .PARAMETER JsonPayload
        The raw JSON response data to store.
    .PARAMETER Metadata
        Hashtable of metadata about the collection.
    .PARAMETER TimestampUtc
        The collection trigger timestamp.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)]$Endpoint,
        [Parameter(Mandatory)][string]$JsonPayload,
        [Parameter(Mandatory)][hashtable]$Metadata,
        [Parameter(Mandatory)][DateTimeOffset]$TimestampUtc,
        # Optional uniqueness label appended to the file name (e.g. an Insights executionId)
        # so multiple writes in the same hour do not collide / overwrite.
        [string]$FileNameSuffix
    )

    $blobConfig = Get-IntegrationConfig
    $storageAccountName = $blobConfig.StorageAccountName
    $containerName = $blobConfig.StorageContainerName

    # Build blob path following the naming convention:
    # {tenant-name}_{tenant-id}/{yyyyMMddHH}/{data-type}/
    $safeTenantName = Get-SafeBlobPathSegment -Value $TenantName
    $datePath = $TimestampUtc.ToString('yyyyMMddHH')
    $dataType = Get-CollectionDataType -Endpoint $Endpoint
    $fileTimestamp = $TimestampUtc.ToString('yyyy-MM-ddTHH-mm-ssZ')
    $endpointName = Get-SafeBlobPathSegment -Value $Endpoint.Name

    $basePath = "${safeTenantName}_${TenantId}/${datePath}/${dataType}"

    $suffix = if ($FileNameSuffix) { "_$(Get-SafeBlobPathSegment -Value $FileNameSuffix)" } else { '' }
    $dataBlobPath = "${basePath}/${endpointName}_${fileTimestamp}${suffix}.json"
    $metadataBlobPath = "${basePath}/${endpointName}_${fileTimestamp}${suffix}_metadata.json"

    # Get storage context using Managed Identity
    $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

    # Write data blob (with retry)
    $dataFile = New-TemporaryFile
    $metadataFile = New-TemporaryFile

    try {
        # Write JSON payload to temp file
        $JsonPayload | Set-Content -Path $dataFile.FullName -Encoding utf8NoBOM

        Invoke-WithRetry -OperationName "BlobWrite:$dataBlobPath" -ScriptBlock {
            Set-AzStorageBlobContent `
                -File $dataFile.FullName `
                -Container $containerName `
                -Blob $dataBlobPath `
                -Context $storageContext `
                -Properties @{ ContentType = 'application/json'; ContentEncoding = 'utf-8' } `
                -Force | Out-Null
        }

        # Write metadata sidecar (with retry)
        $Metadata['blobPath'] = "$containerName/$dataBlobPath"
        $metadataJson = $Metadata | ConvertTo-Json -Depth 5
        $metadataJson | Set-Content -Path $metadataFile.FullName -Encoding utf8NoBOM

        Invoke-WithRetry -OperationName "BlobWrite:$metadataBlobPath" -ScriptBlock {
            Set-AzStorageBlobContent `
                -File $metadataFile.FullName `
                -Container $containerName `
                -Blob $metadataBlobPath `
                -Context $storageContext `
                -Properties @{ ContentType = 'application/json'; ContentEncoding = 'utf-8' } `
                -Force | Out-Null
        }

        Write-Host "Blob stored: $containerName/$dataBlobPath ($($JsonPayload.Length) bytes)"

        return @{
            BlobPath     = "$containerName/$dataBlobPath"
            MetadataPath = "$containerName/$metadataBlobPath"
            BytesWritten = $JsonPayload.Length
        }

    }
    finally {
        Remove-Item $dataFile.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item $metadataFile.FullName -Force -ErrorAction SilentlyContinue
    }
}


function Write-StringToBlob {
    <#
    .SYNOPSIS
        Simple helper to write a string directly to a blob path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$BlobPath,
        [string]$ContainerName,
        [string]$ContentType = 'application/json'
    )

    $blobConfig = Get-IntegrationConfig
    $storageAccountName = $blobConfig.StorageAccountName
    if (-not $ContainerName) {
        $ContainerName = $blobConfig.StorageContainerName
    }

    $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
    $blobProperties = @{ ContentType = $ContentType }

    $tempFile = New-TemporaryFile
    try {
        $Content | Set-Content -Path $tempFile.FullName -Encoding utf8NoBOM

        Invoke-WithRetry -OperationName "BlobWrite:$BlobPath" -ScriptBlock {
            Set-AzStorageBlobContent `
                -File $tempFile.FullName `
                -Container $ContainerName `
                -Blob $BlobPath `
                -Context $storageContext `
                -Properties $blobProperties `
                -Force | Out-Null
        }
    }
    finally {
        Remove-Item $tempFile.FullName -Force -ErrorAction SilentlyContinue
    }
}


function Get-CollectionExecutionMarkerBlobPath {
    <#
    .SYNOPSIS
        Builds a stable marker path for a downloaded Partner Insights execution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)]$Endpoint,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $safeTenantName = Get-SafeBlobPathSegment -Value $TenantName
    $dataType = Get-CollectionDataType -Endpoint $Endpoint
    $endpointName = Get-SafeBlobPathSegment -Value $Endpoint.Name
    $safeExecutionId = Get-SafeBlobPathSegment -Value $ExecutionId

    return "_collection-state/${safeTenantName}_${TenantId}/${dataType}/${endpointName}/${safeExecutionId}.json"
}


function Test-CollectionExecutionSeen {
    <#
    .SYNOPSIS
        Returns true when a prior run already downloaded and marked this executionId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)]$Endpoint,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $blobConfig = Get-IntegrationConfig
    $storageContext = New-AzStorageContext -StorageAccountName $blobConfig.StorageAccountName -UseConnectedAccount
    $markerPath = Get-CollectionExecutionMarkerBlobPath -TenantId $TenantId -TenantName $TenantName -Endpoint $Endpoint -ExecutionId $ExecutionId

    $marker = Invoke-WithRetry -OperationName "BlobExists:$markerPath" -ScriptBlock {
        Get-AzStorageBlob -Container $blobConfig.StorageContainerName -Blob $markerPath -Context $storageContext -ErrorAction SilentlyContinue
    }
    return ($null -ne $marker)
}


function Set-CollectionExecutionSeen {
    <#
    .SYNOPSIS
        Writes a marker after a Partner Insights execution payload has been stored successfully.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)]$Endpoint,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$DataBlobPath,
        [Parameter(Mandatory)][DateTimeOffset]$TimestampUtc
    )

    $markerPath = Get-CollectionExecutionMarkerBlobPath -TenantId $TenantId -TenantName $TenantName -Endpoint $Endpoint -ExecutionId $ExecutionId
    $markerContent = @{
        tenantId     = $TenantId
        tenantName   = $TenantName
        endpointName = $Endpoint.Name
        executionId  = $ExecutionId
        dataBlobPath = $DataBlobPath
        markedUtc    = [DateTimeOffset]::UtcNow.ToString('o')
        triggeredUtc = $TimestampUtc.ToString('o')
    } | ConvertTo-Json -Depth 5

    Write-StringToBlob -Content $markerContent -BlobPath $markerPath | Out-Null
    return $markerPath
}


function Get-CollectionStateBlobPath {
    <#
    .SYNOPSIS
        Builds a stable current-state blob path for singleton control-plane artifacts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)]$Endpoint
    )

    $safeTenantName = Get-SafeBlobPathSegment -Value $TenantName
    $dataType = Get-CollectionDataType -Endpoint $Endpoint
    $endpointName = Get-SafeBlobPathSegment -Value $Endpoint.Name

    return "_collection-state/${safeTenantName}_${TenantId}/${dataType}/${endpointName}.json"
}


function Write-CollectionStateToBlob {
    <#
    .SYNOPSIS
        Writes a singleton current-state JSON artifact and metadata sidecar to stable blob paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$TenantName,
        [Parameter(Mandatory)]$Endpoint,
        [Parameter(Mandatory)][string]$JsonPayload,
        [Parameter(Mandatory)][hashtable]$Metadata
    )

    $blobConfig = Get-IntegrationConfig
    $dataBlobPath = Get-CollectionStateBlobPath -TenantId $TenantId -TenantName $TenantName -Endpoint $Endpoint
    $metadataBlobPath = $dataBlobPath -replace '\.json$', '_metadata.json'

    $Metadata['blobPath'] = "$($blobConfig.StorageContainerName)/$dataBlobPath"
    $Metadata['stateUpdatedUtc'] = [DateTimeOffset]::UtcNow.ToString('o')

    Write-StringToBlob -Content $JsonPayload -BlobPath $dataBlobPath | Out-Null
    Write-StringToBlob -Content ($Metadata | ConvertTo-Json -Depth 5) -BlobPath $metadataBlobPath | Out-Null

    Write-Host "Blob state stored: $($blobConfig.StorageContainerName)/$dataBlobPath ($($JsonPayload.Length) bytes)"

    return @{
        BlobPath     = "$($blobConfig.StorageContainerName)/$dataBlobPath"
        MetadataPath = "$($blobConfig.StorageContainerName)/$metadataBlobPath"
        BytesWritten = $JsonPayload.Length
    }
}


Export-ModuleMember -Function @(
    'Write-CollectionToBlob'
    'Write-StringToBlob'
    'Get-CollectionExecutionMarkerBlobPath'
    'Test-CollectionExecutionSeen'
    'Set-CollectionExecutionSeen'
    'Get-CollectionStateBlobPath'
    'Write-CollectionStateToBlob'
)
