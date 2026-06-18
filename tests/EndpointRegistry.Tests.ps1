BeforeAll {
    $registryPath = Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules' 'EndpointRegistry.psd1'
    $script:Registry = Import-PowerShellDataFile -Path $registryPath
}

Describe 'EndpointRegistry — structure' {
    It 'exposes the three collection groups' {
        $script:Registry.Keys | Should -Contain 'SecurityScoreEndpoints'
        $script:Registry.Keys | Should -Contain 'InsightsCatalog'
        $script:Registry.Keys | Should -Contain 'InsightsReports'
    }
}

Describe 'EndpointRegistry — Partner Security Score (CSP scores)' {
    It 'every security endpoint is Graph beta with required fields' {
        foreach ($ep in $script:Registry.SecurityScoreEndpoints) {
            $ep.Keys | Should -Contain 'Name'
            $ep.Keys | Should -Contain 'Path'
            $ep.ApiSurface | Should -Be 'graph-beta'
            $ep.Path | Should -Match '^/security/partner/securityScore'
            $ep.Frequency | Should -BeIn @('Hourly', 'Every6h', 'Daily')
        }
    }

    It 'includes customerInsights (all CSP customers in one call)' {
        ($script:Registry.SecurityScoreEndpoints | Where-Object { $_.Path -like '*customerInsights' }).Count |
            Should -BeGreaterOrEqual 1
    }

    It 'covers score, requirements and history' {
        $paths = $script:Registry.SecurityScoreEndpoints.Path
        $paths | Should -Contain '/security/partner/securityScore'
        $paths | Should -Contain '/security/partner/securityScore/requirements'
        $paths | Should -Contain '/security/partner/securityScore/history'
    }

    It 'does NOT reference the non-existent securityAlerts endpoint' {
        ($script:Registry.SecurityScoreEndpoints | Where-Object { $_.Path -match 'securityAlerts' }).Count |
            Should -Be 0
    }
}

Describe 'EndpointRegistry — Partner Insights catalog' {
    It 'collects datasets and queries from the Insights surface' {
        $paths = $script:Registry.InsightsCatalog.Path
        $paths | Should -Contain '/ScheduledDataset'
        $paths | Should -Contain '/ScheduledQueries'
        foreach ($c in $script:Registry.InsightsCatalog) {
            $c.ApiSurface | Should -Be 'partner-insights'
        }
    }
}

Describe 'EndpointRegistry — Partner Insights reports' {
    It 'every report definition names a dataset' {
        foreach ($r in $script:Registry.InsightsReports) {
            $r.DatasetName | Should -Not -BeNullOrEmpty
        }
    }

    It 'seeds known datasets with Microsoft system query IDs' {
        $byName = @{}
        foreach ($r in $script:Registry.InsightsReports) { $byName[$r.DatasetName] = $r }
        $byName['CustomersAndTenants'].SystemQueryId | Should -Not -BeNullOrEmpty
        $byName['Profile'].SystemQueryId | Should -Not -BeNullOrEmpty
    }
}
