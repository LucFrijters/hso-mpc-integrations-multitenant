using '../main.bicep'

param environment = 'prod'
param location = 'westeurope'
param baseName = 'hso-mpc-multitenant-integration'
param appClientId = readEnvironmentVariable('APP_CLIENT_ID', '')
param alertEmailAddress = readEnvironmentVariable('ALERT_EMAIL_ADDRESS', 'integration-alerts@hso.com')
// 7.6 is preview/Windows-only. Set to '7.4' to stay on GA support until 2026-11-10.
param powerShellVersion = '7.6'
