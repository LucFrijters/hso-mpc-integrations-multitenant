$script:InsightsClientModulePath = Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules' 'InsightsClient.psm1'
Import-Module $script:InsightsClientModulePath -Force

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules' 'InsightsClient.psm1') -Force
    $script:Config = @{ Insights = @{ ReportNamePrefix = 'hso-auto-'; ReportFormat = 'CSV'; MaxRowsPerReport = 5 } }
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
        New-DatasetSelectQuery -DatasetName 'CustomersAndTenants' -Columns @('CustomerName', 'BilledRevenueUSD') |
        Should -Be 'SELECT CustomerName,BilledRevenueUSD FROM CustomersAndTenants TIMESPAN LAST_6_MONTHS'
    }
    It 'falls back to SELECT * when columns are unknown' {
        New-DatasetSelectQuery -DatasetName 'AzureUsage' |
        Should -Be 'SELECT * FROM AzureUsage TIMESPAN LAST_6_MONTHS'
    }
}

Describe 'Get-InsightsReportName' {
    It 'prefixes the dataset name deterministically (idempotent ensure key)' {
        Get-InsightsReportName -DatasetName 'Profile' -Config $script:Config | Should -Be 'hso-auto-Profile'
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
            [pscustomobject]@{ datasetName = 'CustomersAndTenants'; selectableColumns = @('a') },
            [pscustomobject]@{ datasetName = 'AzureUsage'; selectableColumns = @('x', 'y') }
        )
        $res = Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -EnsureAllDatasets $true
        @($res).Count | Should -Be 2
        ($res | Where-Object { $_.DatasetName -eq 'CustomersAndTenants' }).Source | Should -Be 'registry'
        $auto = $res | Where-Object { $_.DatasetName -eq 'AzureUsage' }
        $auto.Source | Should -Be 'auto'
        $auto.Frequency | Should -Be 'Every4h'
        $auto.CustomQuery | Should -Match 'FROM AzureUsage'
    }
    It 'does not duplicate a dataset already covered by the registry' {
        $registry = @( @{ DatasetName = 'AzureUsage'; SystemQueryId = 'sys-2' } )
        $datasets = @( [pscustomobject]@{ datasetName = 'AzureUsage'; selectableColumns = @('x') } )
        $res = Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -EnsureAllDatasets $true
        @($res).Count | Should -Be 1
        @($res)[0].Source | Should -Be 'registry'
    }
    It 'ignores datasets when EnsureAllDatasets is disabled' {
        $registry = @( @{ DatasetName = 'Profile'; SystemQueryId = 'sys-3' } )
        $datasets = @( [pscustomobject]@{ datasetName = 'AzureUsage'; selectableColumns = @('x') } )
        @(Resolve-InsightsReportsToCollect -RegistryReports $registry -Datasets $datasets -EnsureAllDatasets $false).Count |
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
