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
            $ep.Frequency | Should -BeIn @('Hourly', 'Every4h', 'Every6h')
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

    It 'includes all documented Partner Insights system queries' {
        $expected = @{
            CustomersAndTenants              = '6664daf3-c161-423a-92a1-0ea6db2c0384'
            SeatsSubscriptionsAndRevenue     = 'c9fc1c79-4408-49ff-97f9-e1aa3f155804'
            Profile                          = 'e65f3a4f-fb99-4319-97ff-59e57566a871'
            AzureUsage                       = 'd1a4d75e-5ca8-4847-845f-ee0a9be6f07b'
            OfficeUsage                      = 'd8349f7b-a7d1-467e-b26d-434d4a50f26a'
            DynamicsUsage                    = '6209a8fd-93af-442e-8b3f-3df0f77e8463'
            PowerBIUsage                     = '40ebfe2f-7183-4427-a911-5c9b45b6df15'
            EMSUsage                         = 'd7f20ea4-8751-4d6b-b1d7-821c316acd6a'
            CloudProductsResellerPerformance = 'c09c2eda-861b-4664-8ee8-48a14745a26a'
            CLASAgreementRenewalsPropensity  = 'c4fc87ac-4cca-44cd-bf4d-835ac513f9ee'
            CLASAzurePropensity              = '9a18bd70-8f90-4bd2-8266-5f6e453e3ee7'
            CLASD365Propensity               = '258fdcac-6e9c-4072-af27-b1b3d97be16c'
            CLASM365Propensity               = 'fbe00e32-fdde-4465-b3e4-41bbd021a130'
            CLASSurfacePropensity            = 'ba339743-7594-439f-bb01-1a2e754df7b7'
            TeamsUsage3PApps                 = '42d287be-cc76-4109-a066-f3140ad97fe2'
            TeamsUsageWorkload               = '817fe875-acb0-4c45-9201-b7a35a60235a'
            TeamsUsageMeetingsAndCalls       = 'b7bd73a8-47e8-4c57-b915-445708cfd7bf'
            TrainingCompletions              = '20f5da57-3c2a-481b-b6a0-ec34d6db14e2'
            MSLearn                          = '0e06c7c3-75ab-4cd5-8178-8cf1a2de49cc'
        }

        @($script:Registry.InsightsReports).Count | Should -Be 19
        $byName = @{}
        foreach ($report in $script:Registry.InsightsReports) { $byName[$report.DatasetName] = $report.SystemQueryId }
        foreach ($datasetName in $expected.Keys) {
            $byName[$datasetName] | Should -Be $expected[$datasetName]
        }
    }
}
