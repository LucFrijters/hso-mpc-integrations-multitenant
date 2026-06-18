@{
    # Repository-wide PSScriptAnalyzer configuration.
    # Excludes rules that conflict with Azure Functions PowerShell conventions
    # or are overly strict for internal helper scripts.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Azure Functions log streams use Write-Host by design (captured to App Insights).
        'PSAvoidUsingWriteHost',
        # Internal helper functions (e.g. Split-IntoBatches) intentionally use plural nouns.
        'PSUseSingularNouns',
        # Token/JWT factories don't change persisted state — ShouldProcess not applicable.
        'PSUseShouldProcessForStateChangingFunctions',
        # BOM is not required for UTF-8 source files used by PowerShell 7.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
