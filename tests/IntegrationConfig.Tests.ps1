BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules' 'IntegrationConfig.psm1'
    Import-Module $modulePath -Force
}

Describe 'Get-ApiSurfaceTokenScope' {
    It 'uses the delegated Partner Center scope for AppPlusUser' {
        Get-ApiSurfaceTokenScope -ApiSurface 'partner-insights' -AuthMode AppPlusUser |
        Should -Be 'https://api.partnercenter.microsoft.com/user_impersonation'
    }

    It 'uses the application .default scope for Partner Center AppOnly' {
        Get-ApiSurfaceTokenScope -ApiSurface 'partner-insights' -AuthMode AppOnly |
        Should -Be 'https://api.partnercenter.microsoft.com/.default'
    }

    It 'adds offline_access for the one-time authorization-code consent flow' {
        Get-ApiSurfaceTokenScope -ApiSurface 'partner-insights' -AuthMode AppPlusUser -IncludeOfflineAccess |
        Should -Be 'offline_access https://api.partnercenter.microsoft.com/user_impersonation'
    }
}

Describe 'Partner Insights documentation references' {
    It 'exposes Microsoft Learn schema and system-query reference URLs' {
        $config = Get-IntegrationConfig
        $config.Insights.DataDefinitionsUrl | Should -Be 'https://learn.microsoft.com/en-us/partner-center/insights/insights-data-definitions'
        $config.Insights.SystemQueriesUrl | Should -Be 'https://learn.microsoft.com/en-us/partner-center/insights/insights-programmatic-system-queries'
    }
}