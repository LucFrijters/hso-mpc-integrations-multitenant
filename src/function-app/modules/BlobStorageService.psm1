<#
.SYNOPSIS
    Blob Storage module for writing collected API data and metadata to Azure Blob Storage.
    Uses Managed Identity for authentication (no storage keys).
#>

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

    # Sanitize tenant name for use in blob path
    $safeTenantName = $TenantName -replace '[^a-zA-Z0-9\-]', '-' | ForEach-Object { $_.ToLower() }

    # Build blob path following the naming convention:
    # {tenant-name}_{tenant-id}/{api-surface}/{category}/{endpoint-name}/{yyyy}/{MM}/{dd}/{HH}/
    $datePath = $TimestampUtc.ToString('yyyy/MM/dd/HH')
    $fileTimestamp = $TimestampUtc.ToString('yyyy-MM-ddTHH-mm-ssZ')
    $endpointName = $Endpoint.Name

    $basePath = "${safeTenantName}_${TenantId}/$($Endpoint.ApiSurface)/$($Endpoint.Category)/${endpointName}/${datePath}"

    $suffix = if ($FileNameSuffix) { "_$($FileNameSuffix -replace '[^a-zA-Z0-9\-]', '-')" } else { '' }
    $dataBlobPath = "${basePath}/${endpointName}_${fileTimestamp}${suffix}.json"
    $metadataBlobPath = "${basePath}/_metadata_${fileTimestamp}${suffix}.json"

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


Export-ModuleMember -Function @(
    'Write-CollectionToBlob'
    'Write-StringToBlob'
)
