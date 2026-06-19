$script:InsightsClientModulePath = Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules' 'InsightsClient.psm1'
Import-Module $script:InsightsClientModulePath -Force

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules' 'InsightsClient.psm1') -Force
    $script:Config = @{ Insights = @{ ReportNamePrefix = 'hso-auto-'; ReportFormat = 'CSV'; MaxRowsPerReport = 5; RecurrenceIntervalHours = 4; RecurrenceCount = 2190 } }
}

Describe 'Convert-DelimitedToJson' {
    It 'parses CSV header + rows into objects' {
        $csv = "Name,Revenue`nContoso,100`nFabrikam,200"
        $r = Convert-DelimitedToJson -Content $csv -Format CSV
        $r.RowCount | Should -Be 2
        ($r.Json | ConvertFrom-Json)[0].Name | Should -Be 'Contoso'
        ($r.Json | ConvertFrom-Json)[1].Revenue | Should -Be '200'
    }
    It 'parses TSV using a tab delimiter' {
        $tsv = "Name`tCity`nA`tAmsterdam"
        (Convert-DelimitedToJson -Content $tsv -Format TSV).Json | ConvertFrom-Json |
        Select-Object -ExpandProperty City | Should -Be 'Amsterdam'
    }
    It 'returns an empty JSON array for empty content' {
        (Convert-DelimitedToJson -Content '').Json | Should -Be '[]'
    }
    It 'emits a JSON array even for a single row' {
        (Convert-DelimitedToJson -Content "A,B`n1,2" -Format CSV).Json.TrimStart()[0] | Should -Be '['
    }
    It 'honours the MaxRows truncation guard' {
        $rows = (1..10 | ForEach-Object { "$_,x" }) -join "`n"
        $r = Convert-DelimitedToJson -Content "Id,V`n$rows" -Format CSV -MaxRows 3
        $r.RowCount | Should -Be 3
        $r.Truncated | Should -BeTrue
    }
}

Describe 'New-DatasetSelectQuery' {
    It 'builds an explicit column projection with a timespan' {
        New-DatasetSelectQuery -DatasetName 'CustomersAndTenants' -Columns @('CustomerName', 'BilledRevenueUSD') -Timespan 'LAST_6_MONTHS' |
        Should -Be 'SELECT CustomerName,BilledRevenueUSD FROM CustomersAndTenants TIMESPAN LAST_6_MONTHS'
    }
    It 'omits TIMESPAN when the dataset publishes no available date ranges' {
        New-DatasetSelectQuery -DatasetName 'Profile' -Columns @('PartnerId', 'PartnerName') |
        Should -Be 'SELECT PartnerId,PartnerName FROM Profile'
    }
    It 'throws instead of generating an invalid SELECT wildcard' {
        { New-DatasetSelectQuery -DatasetName 'AzureUsage' -Columns @() } |
        Should -Throw '*no selectableColumns*'
    }
}

Describe 'Partner Insights dataset recurrence and date ranges' {
    It 'clamps dataset minimum recurrence to the Partner Center allowed range' {
        Get-ClampedInsightsRecurrenceInterval -MinimumRecurrenceIntervalHours 1 | Should -Be 4
        Get-ClampedInsightsRecurrenceInterval -MinimumRecurrenceIntervalHours 24 | Should -Be 24
        Get-ClampedInsightsRecurrenceInterval -MinimumRecurrenceIntervalHours 3000 | Should -Be 2160
    }
    It 'reads minimumRecurrenceInterval and availableDateRanges from dataset metadata' {
        $dataset = [pscustomobject]@{
            datasetName               = 'OfficeUsage'
            minimumRecurrenceInterval = 24
            availableDateRanges       = @('LAST_MONTH', 'LAST_6_MONTHS')
        }
        Get-InsightsDatasetMinimumRecurrenceInterval -Dataset $dataset | Should -Be 24
        Select-InsightsDatasetTimespan -Dataset $dataset | Should -Be 'LAST_6_MONTHS'
    }
    It 'returns no TIMESPAN for datasets without availableDateRanges' {
        Select-InsightsDatasetTimespan -Dataset ([pscustomobject]@{ datasetName = 'Profile' }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-InsightsReportName' {
    It 'prefixes the dataset name deterministically (idempotent ensure key)' {
        Get-InsightsReportName -DatasetName 'Profile' -Config $script:Config | Should -Be 'hso-auto-Profile'
    }
}

Describe 'Get-InsightsQueryName' {
    It 'builds names accepted by ScheduledQueries: alphanumerics and whitespace only' {
        $name = Get-InsightsQueryName -DatasetName 'CLASAgreementRenewalsPropensity' -Config $script:Config
        $name | Should -Match '^[a-zA-Z0-9\s]+$'
        $name | Should -Match 'hso auto CLASAgreementRenewalsPropensity query'
    }
}

Describe 'Register-InsightsReport' {
    It 'reuses an existing report and returns its query id without creating anything' {
        $definition = @{ DatasetName = 'CustomersAndTenants'; SystemQueryId = 'system-query-id' }
        $existingReports = @([pscustomobject]@{
                reportName   = 'hso-auto-CustomersAndTenants'
                reportId     = 'existing-report-id'
                queryId      = 'existing-query-id'
                reportStatus = 'Active'
            })

        $result = Register-InsightsReport -Definition $definition -ExistingReports $existingReports `
            -AccessToken 'unused' -Config $script:Config

        $result.ReportId | Should -Be 'existing-report-id'
        $result.QueryId | Should -Be 'existing-query-id'
        $result.Created | Should -BeFalse
        $result.QueryCreated | Should -BeFalse
        $result.QueryResponse | Should -BeNullOrEmpty
        $result.ReportResponse | Should -BeNullOrEmpty
    }
}

Describe 'Partner Insights response envelopes' {
    It 'throws when an HTTP 200 body carries an error statusCode' {
        $body = [pscustomobject]@{ statusCode = 400; message = 'Invalid query' }
        { Assert-InsightsResponseSuccess -Body $body -Path 'https://api.partnercenter.microsoft.com/insights/v1/mpn/ScheduledQueries' -Method POST } |
        Should -Throw '*statusCode=400*Invalid query*'
    }
    It 'allows successful response envelopes' {
        { Assert-InsightsResponseSuccess -Body ([pscustomobject]@{ statusCode = 200; message = 'OK' }) -Path '/ScheduledDataset' -Method GET } |
        Should -Not -Throw
    }
}

Describe 'Partner Insights scheduled report reuse' {
    It 'reuses only Active reports' {
        Test-InsightsReportIsReusable ([pscustomobject]@{ reportStatus = 'Active' }) | Should -BeTrue
        Test-InsightsReportIsReusable ([pscustomobject]@{ reportStatus = 'Paused' }) | Should -BeFalse
        Test-InsightsReportIsReusable ([pscustomobject]@{ reportStatus = 'Inactive' }) | Should -BeFalse
    }
    It 'matches recreated report names by deterministic base prefix' {
        $report = [pscustomobject]@{ reportName = 'hso-auto-OfficeUsage-20260619170500' }
        Test-InsightsReportNameMatches -Report $report -ReportName 'hso-auto-OfficeUsage' | Should -BeTrue
    }
}

Describe 'Partner Insights system query compatibility' {
    It 'extracts query projection columns' {
        Get-InsightsQueryProjectionColumns -Query 'SELECT A,B, C FROM SomeDataset TIMESPAN LAST_6_MONTHS' |
        Should -Be @('A', 'B', 'C')
    }
    It 'detects projected columns missing from the live dataset schema' {
        Get-InsightsQueryMissingColumns -Query 'SELECT A,B FROM SomeDataset' -DatasetColumns @('A') |
        Should -Be @('B')
    }
}

Describe 'Insights dataset accessors (defensive across field spellings)' {
    It 'reads the dataset name across spellings' {
        Get-InsightsDatasetName ([pscustomobject]@{ datasetName = 'X' }) | Should -Be 'X'
        Get-InsightsDatasetName ([pscustomobject]@{ Name = 'Y' })        | Should -Be 'Y'
    }
    It 'extracts columns from string arrays and object arrays' {
        Get-InsightsDatasetColumns ([pscustomobject]@{ selectableColumns = @('a', 'b') }) | Should -Be @('a', 'b')
        (Get-InsightsDatasetColumns ([pscustomobject]@{ columns = @([pscustomobject]@{ name = 'c' }) }))[0] | Should -Be 'c'
    }
}

Describe 'Resolve-InsightsReportsToCollect' {
    It 'keeps registry entries and adds auto reports for remaining datasets' {
        $registry = @( @{ DatasetName = 'CustomersAndTenants'; SystemQueryId = 'sys-1' } )
        $datasets = @(
            [pscustomobject]@{ datasetName = 'CustomersAndTenants'; selectableColumns = @('a'); minimumRecurrenceInterval = 4; availableDateRanges = @('LAST_6_MONTHS') },
            [pscustomobject]@{ datasetName = 'AzureUsage'; selectableColumns = @('x', 'y'); minimumRecurrenceInterval = 24; availableDateRanges = @('LAST_MONTH') }
        )
        $queries = @( [pscustomobject]@{ queryId = 'sys-1'; query = 'SELECT a FROM CustomersAndTenants TIMESPAN LAST_6_MONTHS' } )
        $res = Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -Queries $queries -EnsureAllDatasets $true
        @($res).Count | Should -Be 2
        ($res | Where-Object { $_.DatasetName -eq 'CustomersAndTenants' }).Source | Should -Be 'registry'
        $auto = $res | Where-Object { $_.DatasetName -eq 'AzureUsage' }
        $auto.Source | Should -Be 'auto'
        $auto.Frequency | Should -Be 'Every24h'
        $auto.RecurrenceIntervalHours | Should -Be 24
        $auto.Timespan | Should -Be 'LAST_MONTH'
        $auto.CustomQuery | Should -Be 'SELECT x,y FROM AzureUsage TIMESPAN LAST_MONTH'
    }
    It 'does not duplicate a dataset already covered by the registry' {
        $registry = @( @{ DatasetName = 'AzureUsage'; SystemQueryId = 'sys-2' } )
        $datasets = @( [pscustomobject]@{ datasetName = 'AzureUsage'; selectableColumns = @('x') } )
        $queries = @( [pscustomobject]@{ queryId = 'sys-2'; query = 'SELECT x FROM AzureUsage' } )
        $res = Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -Queries $queries -EnsureAllDatasets $true
        @($res).Count | Should -Be 1
        @($res)[0].Source | Should -Be 'registry'
    }
    It 'skips registry-backed system queries when the dataset is absent from the partner catalog' {
        $registry = @(
            @{ DatasetName = 'OfficeUsage'; SystemQueryId = 'sys-office' },
            @{ DatasetName = 'MissingDataset'; SystemQueryId = 'sys-missing' }
        )
        $datasets = @( [pscustomobject]@{ datasetName = 'OfficeUsage'; selectableColumns = @('tenantId') } )
        $queries = @( [pscustomobject]@{ queryId = 'sys-office'; query = 'SELECT tenantId FROM OfficeUsage' } )
        $res = Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -Queries $queries -EnsureAllDatasets $true
        @($res).Count | Should -Be 1
        @($res)[0].DatasetName | Should -Be 'OfficeUsage'
    }
    It 'applies dataset minimum recurrence to registry-backed system query reports' {
        $registry = @( @{ DatasetName = 'OfficeUsage'; SystemQueryId = 'sys-office' } )
        $datasets = @( [pscustomobject]@{ datasetName = 'OfficeUsage'; selectableColumns = @('tenantId'); minimumRecurrenceInterval = 24 } )
        $queries = @( [pscustomobject]@{ queryId = 'sys-office'; query = 'SELECT tenantId FROM OfficeUsage' } )
        $res = Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -Queries $queries -EnsureAllDatasets $true
        @($res).Count | Should -Be 1
        @($res)[0].RecurrenceIntervalHours | Should -Be 24
        @($res)[0].Frequency | Should -Be 'Every24h'
    }
    It 'falls back to generated query when a system query references missing live columns' {
        $registry = @( @{ DatasetName = 'Profile'; SystemQueryId = 'sys-profile' } )
        $datasets = @( [pscustomobject]@{ datasetName = 'Profile'; selectableColumns = @('MpnId', 'PartnerName') } )
        $queries = @( [pscustomobject]@{ queryId = 'sys-profile'; query = 'SELECT MpnId,PartnerName,HierarchyLevel FROM Profile' } )
        $res = Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -Queries $queries -EnsureAllDatasets $true
        @($res).Count | Should -Be 1
        @($res)[0].Source | Should -Be 'registry-schema-fallback'
        @($res)[0].SystemQueryId | Should -BeNullOrEmpty
        @($res)[0].CustomQuery | Should -Be 'SELECT MpnId,PartnerName FROM Profile'
        @($res)[0].MissingSystemQueryColumns | Should -Be @('HierarchyLevel')
    }
    It 'skips generated reports for datasets without selectableColumns' {
        $registry = @()
        $datasets = @(
            [pscustomobject]@{ datasetName = 'Profile'; availableDateRanges = @() },
            [pscustomobject]@{ datasetName = 'AzureUsage'; selectableColumns = @('usageDate') }
        )
        $res = Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -Queries @() -EnsureAllDatasets $true
        @($res).Count | Should -Be 1
        @($res)[0].DatasetName | Should -Be 'AzureUsage'
    }
    It 'ignores datasets when EnsureAllDatasets is disabled' {
        $registry = @( @{ DatasetName = 'Profile'; SystemQueryId = 'sys-3' } )
        $datasets = @(
            [pscustomobject]@{ datasetName = 'Profile'; selectableColumns = @('partnerId') },
            [pscustomobject]@{ datasetName = 'AzureUsage'; selectableColumns = @('x') }
        )
        $queries = @( [pscustomobject]@{ queryId = 'sys-3'; query = 'SELECT partnerId FROM Profile' } )
        @(Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -Queries $queries -EnsureAllDatasets $false).Count |
        Should -Be 1
    }
}

Describe 'Partner Center MFA validation' {
    InModuleScope InsightsClient {
        It 'reads isMfaCompliant response headers case-insensitively' {
            $response = [pscustomobject]@{ Headers = @{ 'isMfaCompliant' = @('true') } }
            Get-HttpResponseHeaderValue -Response $response -Name 'ismfacompliant' | Should -Be 'true'
        }

        It 'throws when Partner Center reports a non-MFA-compliant token' {
            $response = [pscustomobject]@{ Headers = @{ 'isMfaCompliant' = 'false' } }
            { Assert-PartnerCenterMfaCompliance -Response $response -Uri 'https://api.partnercenter.microsoft.com/insights/v1/mpn/ScheduledDataset' } |
            Should -Throw '*MFA validation failed*'
        }
    }
}
