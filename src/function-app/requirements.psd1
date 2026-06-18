# This file enables modules to be automatically managed by the host.
# See https://aka.ms/functionsmanageddependency for additional information.
#
# Runtime: PowerShell 7.6 (Windows, .NET 10). The Az modules below target .NET Standard 2.0
# and load on .NET 10. Keep them on a currently-supported Az release (Az 15.x family or later);
# the major pins resolve to the latest published minor at managed-dependency restore time.
@{
    # Modules required by the function app
    'Az.Accounts'        = '3.*'
    'Az.KeyVault'        = '6.*'
    'Az.Storage'         = '7.*'
}
