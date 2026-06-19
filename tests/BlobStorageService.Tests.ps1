BeforeAll {
    $modulesPath = Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules'
    Import-Module (Join-Path $modulesPath 'IntegrationConfig.psm1') -Force
    Import-Module (Join-Path $modulesPath 'BlobStorageService.psm1') -Force
}

Describe 'Get-OrchestrationSummaryDataType' {
    It 'maps Partner Insights results to the summary data-type folder' {
        $result = @{ EndpointName = 'partner-insights'; Category = 'insights'; ApiSurface = 'partner-insights' }

        Get-OrchestrationSummaryDataType -Value $result | Should -Be 'partner-insights-reports'
    }

    It 'maps Graph security score results to the requested summary data-type folder' {
        $result = @{ EndpointName = 'security-score'; Category = 'partner-security-score'; ApiSurface = 'graph-beta' }

        Get-OrchestrationSummaryDataType -Value $result | Should -Be 'partner-security-score'
    }
}

Describe 'Get-OrchestrationSummaryBlobPath' {
    It 'stores Partner Insights orchestration summaries under the data source folder' {
        $path = Get-OrchestrationSummaryBlobPath `
            -TenantId 'ba14e008-6e09-40dd-a908-1cae691d5b07' `
            -TenantName 'HSO Production' `
            -DataType 'partner-insights-reports' `
            -CompletedUtc ([DateTimeOffset]'2026-06-19T17:45:58Z')

        $path | Should -Be 'hso-production_ba14e008-6e09-40dd-a908-1cae691d5b07/partner-insights-reports/_orchestration-summaries/orchestration-summary_2026-06-19T17-45-58Z.json'
    }

    It 'sanitizes tenant display names like collection-state paths' {
        $path = Get-OrchestrationSummaryBlobPath `
            -TenantId 'tenant-1' `
            -TenantName 'Partner & Co / NL' `
            -DataType 'partner-security-score' `
            -CompletedUtc ([DateTimeOffset]'2026-06-19T17:45:58Z')

        $path | Should -Be 'partner---co---nl_tenant-1/partner-security-score/_orchestration-summaries/orchestration-summary_2026-06-19T17-45-58Z.json'
    }
}

Describe 'Get-OrchestrationSummaryArchiveBlobPath' {
    It 'keeps the legacy archive helper compatible with the timestamped summary path' {
        $path = Get-OrchestrationSummaryArchiveBlobPath `
            -TenantId 'ba14e008-6e09-40dd-a908-1cae691d5b07' `
            -TenantName 'HSO Production' `
            -DataType 'partner-security-score' `
            -CompletedUtc ([DateTimeOffset]'2026-06-19T17:45:58Z')

        $path | Should -Be 'hso-production_ba14e008-6e09-40dd-a908-1cae691d5b07/partner-security-score/_orchestration-summaries/orchestration-summary_2026-06-19T17-45-58Z.json'
    }
}

Describe 'Get-LegacyOrchestrationSummaryArchiveBlobPath' {
    It 'does not create root-level archives for legacy hourly summary artifacts' {
        $path = Get-LegacyOrchestrationSummaryArchiveBlobPath -BlobPath '_orchestration-summaries/2026061917/summary_2026-06-19T17-45-58Z.json'

        $path | Should -BeNullOrEmpty
    }

    It 'does not create root-level archives for nested legacy hourly artifacts' {
        $path = Get-LegacyOrchestrationSummaryArchiveBlobPath -BlobPath '_orchestration-summaries/2026061917/archive/summary_2026-06-19T17-45-58Z.json'

        $path | Should -BeNullOrEmpty
    }

    It 'does not create root-level archives for old lowercase archive paths' {
        $path = Get-LegacyOrchestrationSummaryArchiveBlobPath -BlobPath '_orchestration-summaries/archive/2026061917/summary_2026-06-19T17-45-58Z.json'

        $path | Should -BeNullOrEmpty
    }

    It 'does not move current data-type summary artifacts' {
        $path = Get-LegacyOrchestrationSummaryArchiveBlobPath -BlobPath 'hso-production_ba14e008-6e09-40dd-a908-1cae691d5b07/partner-insights-reports/_orchestration-summaries/orchestration-summary_2026-06-19T17-45-58Z.json'

        $path | Should -BeNullOrEmpty
    }
}

Describe 'Get-CollectionStateBlobPath' {
    It 'stores Partner Insights catalogs under the catalog folder' {
        $endpoint = @{ Name = 'datasets'; Category = 'insights-catalog'; ApiSurface = 'partner-insights' }

        $path = Get-CollectionStateBlobPath `
            -TenantId '9bc096ab-f225-476e-8e92-260401469868' `
            -TenantName 'HSO Production' `
            -Endpoint $endpoint

        $path | Should -Be 'hso-production_9bc096ab-f225-476e-8e92-260401469868/partner-insights-reports/catalog/datasets.json'
    }

    It 'stores created query/report control responses in the data source current-state folder' {
        $endpoint = @{ Name = 'BusinessApplicationsRevenue-created-query'; Category = 'insights-control'; ApiSurface = 'partner-insights' }

        $path = Get-CollectionStateBlobPath `
            -TenantId '9bc096ab-f225-476e-8e92-260401469868' `
            -TenantName 'HSO Production' `
            -Endpoint $endpoint

        $path | Should -Be 'hso-production_9bc096ab-f225-476e-8e92-260401469868/partner-insights-reports/_collection-state/businessapplicationsrevenue-created-query.json'
    }
}

Describe 'Get-CollectionStateArchiveBlobPath' {
    It 'archives Partner Insights catalog versions under catalog _Archive' {
        $endpoint = @{ Name = 'datasets'; Category = 'insights-catalog'; ApiSurface = 'partner-insights' }

        $path = Get-CollectionStateArchiveBlobPath `
            -TenantId '9bc096ab-f225-476e-8e92-260401469868' `
            -TenantName 'HSO Production' `
            -Endpoint $endpoint `
            -TimestampUtc ([DateTimeOffset]'2026-06-19T17:45:58Z')

        $path | Should -Be 'hso-production_9bc096ab-f225-476e-8e92-260401469868/partner-insights-reports/catalog/_Archive/datasets_2026-06-19T17-45-58Z.json'
    }

    It 'archives current-state control versions under _collection-state _Archive' {
        $endpoint = @{ Name = 'BusinessApplicationsRevenue-created-query'; Category = 'insights-control'; ApiSurface = 'partner-insights' }

        $path = Get-CollectionStateArchiveBlobPath `
            -TenantId '9bc096ab-f225-476e-8e92-260401469868' `
            -TenantName 'HSO Production' `
            -Endpoint $endpoint `
            -TimestampUtc ([DateTimeOffset]'2026-06-19T17:45:58Z')

        $path | Should -Be 'hso-production_9bc096ab-f225-476e-8e92-260401469868/partner-insights-reports/_collection-state/_Archive/businessapplicationsrevenue-created-query_2026-06-19T17-45-58Z.json'
    }
}

Describe 'Get-CollectionExecutionMarkerBlobPath' {
    It 'stores execution markers inside the data source current-state folder' {
        $endpoint = @{ Name = 'CustomersAndTenants'; Category = 'insights-reports'; ApiSurface = 'partner-insights' }

        $path = Get-CollectionExecutionMarkerBlobPath `
            -TenantId '9bc096ab-f225-476e-8e92-260401469868' `
            -TenantName 'HSO Production' `
            -Endpoint $endpoint `
            -ExecutionId 'exec-123'

        $path | Should -Be 'hso-production_9bc096ab-f225-476e-8e92-260401469868/partner-insights-reports/_collection-state/execution-markers/customersandtenants/exec-123.json'
    }
}