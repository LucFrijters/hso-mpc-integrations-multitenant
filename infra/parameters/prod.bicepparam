using '../main.bicep'

param environment = 'prd'
param location = 'westeurope'
param baseName = 'hso-mpc-integration-prd-westeu'
param appClientId = '05573d61-6ddf-403b-90c6-d8572e6c867f'
param alertEmailAddress = 'lfrijters@hso.com'
// 7.6 is preview/Windows-only. Set to '7.4' to stay on GA support until 2026-11-10.
param powerShellVersion = '7.6'
