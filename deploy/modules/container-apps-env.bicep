// ============================================================
// modules/container-apps-env.bicep
// ============================================================
// Provisions a shared Container Apps Managed Environment using
// the Consumption workload profile.
//
// Cost: $0 — the Consumption profile has no fixed infrastructure
// fee; you pay only for vCore-seconds and GB-seconds actually
// consumed, and both have generous monthly free grants:
//   • 180,000 vCore-seconds / month
//   • 360,000 GB-seconds  / month
//
// Both the Functions Container App and the API Container App
// share this environment so there is still only one environment.
// ============================================================

param prefix   string
param location string
param tags     object

var envName = '${prefix}-aca-env'

resource containerAppsEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  tags: tags
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

@description('Resource ID of the Container Apps Managed Environment')
output envId string = containerAppsEnv.id
