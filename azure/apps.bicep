// Second deployment: the two Container Apps (backend + frontend).
// Assumes infrastructure.bicep has already created the registry (ACR)
// and the Container Apps environment.

param location string = resourceGroup().location
param acrName string
param environmentName string

@description('Prefix for the Azure resource names, e.g. team1 -> team1-backend, team1-frontend')
param appPrefix string

@description('Backend image as repository:tag, e.g. team1-backend:20261013120000')
param backendImage string

@description('Frontend image as repository:tag, e.g. team1-frontend:20261013120000')
param frontendImage string

@secure()
@description('Backend environment variables (read from team1_backend/.env). Each one is stored as a Container App secret.')
param backendEnv object

var backendAppName = '${appPrefix}-backend'
var frontendAppName = '${appPrefix}-frontend'

// ---------- Existing resources from infrastructure.bicep ----------

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: environmentName
}

// ---------- Identity that is allowed to pull images from the registry ----------

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${appPrefix}-acr-pull'
  location: location
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, pullIdentity.id, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // built-in AcrPull role
    )
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Backend: FastAPI, reachable only from inside the environment ----------

resource backend 'Microsoft.App/containerApps@2025-01-01' = {
  name: backendAppName
  location: location

  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentity.id}': {}
    }
  }

  properties: {
    managedEnvironmentId: environment.id

    configuration: {
      activeRevisionsMode: 'Single'

      ingress: {
        external: false // no public URL; only the frontend can call it
        targetPort: 8000
        transport: 'auto'
        allowInsecure: true // lets nginx call it over plain http inside the environment
      }

      registries: [
        {
          server: acr.properties.loginServer
          identity: pullIdentity.id
        }
      ]

      // AZURE_OPENAI_API_KEY -> secret "azure-openai-api-key", etc.
      secrets: [
        for item in items(backendEnv): {
          name: toLower(replace(item.key, '_', '-'))
          #disable-next-line use-secure-value-for-secure-inputs // value comes from the @secure() backendEnv param
          value: item.value
        }
      ]
    }

    template: {
      containers: [
        {
          name: 'backend'
          image: '${acr.properties.loginServer}/${backendImage}'

          // Each secret becomes an environment variable with its original name
          env: [
            for item in items(backendEnv): {
              name: item.key
              secretRef: toLower(replace(item.key, '_', '-'))
            }
          ]

          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]

      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }

  dependsOn: [
    acrPull
  ]
}

// ---------- Frontend: Angular served by nginx, public URL ----------

resource frontend 'Microsoft.App/containerApps@2025-01-01' = {
  name: frontendAppName
  location: location

  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentity.id}': {}
    }
  }

  properties: {
    managedEnvironmentId: environment.id

    configuration: {
      activeRevisionsMode: 'Single'

      ingress: {
        external: true
        targetPort: 80
        transport: 'auto'
      }

      registries: [
        {
          server: acr.properties.loginServer
          identity: pullIdentity.id
        }
      ]
    }

    template: {
      containers: [
        {
          name: 'frontend'
          image: '${acr.properties.loginServer}/${frontendImage}'

          env: [
            {
              // nginx forwards /api/* here. Inside a Container Apps environment,
              // another app is reachable at http://<its-name>.
              name: 'BACKEND_URL'
              value: 'http://${backend.name}'
            }
          ]

          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]

      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }

  dependsOn: [
    acrPull
  ]
}

output url string = 'https://${frontend.properties.configuration.ingress.fqdn}'
