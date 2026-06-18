using '../main.bicep'

param environment = 'dev'
param location = 'westeurope'
param baseName = 'hso-mpc-multitenant-integration'
param appClientId = readEnvironmentVariable('APP_CLIENT_ID', '')
param alertEmailAddress = readEnvironmentVariable('ALERT_EMAIL_ADDRESS', 'integration-alerts@hso.com')
param powerShellVersion = '7.6'
