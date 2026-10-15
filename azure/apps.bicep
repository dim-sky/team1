// Second deployment: the Container Apps (backend, frontend, Neo4j) and the
// graph loader job. Assumes infrastructure.bicep has already created the
// registry (ACR) and the Container Apps environment.

param location string = resourceGroup().location
param acrName string
param environmentName string

@description('Prefix for the Azure resource names, e.g. team1 -> team1-backend, team1-frontend')
param appPrefix string

@description('Backend image as repository:tag, e.g. team1-backend:20261013120000')
param backendImage string

@description('Frontend image as repository:tag, e.g. team1-frontend:20261013120000')
param frontendImage string

@description('Neo4j image as repository:tag, imported into the registry by deploy.ps1')
param neo4jImage string = 'neo4j:5.26'

@description('Graph loader image as repository:tag, e.g. team1-knowledge-graph:20261013120000')
param graphLoaderImage string

@description('Databricks schema that holds the gold tables')
param goldSchema string = 'data2026acc123456.team1'

@description('When the graph loader runs by itself, as a cron expression in UTC. Default: every night at 03:00.')
param loaderSchedule string = '0 3 * * *'

@secure()
@description('Backend environment variables (read from backend/.env). Each one is stored as a Container App secret.')
param backendEnv object

@secure()
@description('Knowledge graph environment variables (read from knowledge-graph/.env): NEO4J_AUTH and the Databricks settings.')
param graphEnv object

var backendAppName = '${appPrefix}-backend'
var frontendAppName = '${appPrefix}-frontend'
var neo4jAppName = '${appPrefix}-neo4j'
var graphLoaderJobName = '${appPrefix}-graph-loader'

// Graph loader env vars that point at secrets (names only, no values)
var graphSecretEnv = [
  for item in items(graphEnv): {
    name: item.key
    secretRef: toLower(replace(item.key, '_', '-'))
  }
]

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

// ---------- Neo4j: graph database, reachable only from inside the environment ----------

resource neo4j 'Microsoft.App/containerApps@2025-01-01' = {
  name: neo4jAppName
  location: location

  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentity.id}': {}
    }
  }

  properties: {
    managedEnvironmentId: environment.id
    workloadProfileName: 'Consumption'

    configuration: {
      activeRevisionsMode: 'Single'

      // Bolt protocol. Other apps and the loader job connect to bolt://<this app's name>:7687
      ingress: {
        external: false
        transport: 'tcp'
        targetPort: 7687
        exposedPort: 7687
      }

      registries: [
        {
          server: acr.properties.loginServer
          identity: pullIdentity.id
        }
      ]

      secrets: [
        {
          name: 'neo4j-auth'
          #disable-next-line use-secure-value-for-secure-inputs // value comes from the @secure() graphEnv param
          value: graphEnv.NEO4J_AUTH
        }
      ]
    }

    template: {
      containers: [
        {
          name: 'neo4j'
          image: '${acr.properties.loginServer}/${neo4jImage}'

          env: [
            {
              name: 'NEO4J_AUTH'
              secretRef: 'neo4j-auth'
            }
            // Same memory settings as docker-compose.yml
            {
              name: 'NEO4J_server_memory_heap_max__size'
              value: '1G'
            }
            {
              name: 'NEO4J_server_memory_pagecache_size'
              value: '512M'
            }
          ]

          // Heap + page cache + JVM overhead need more than 2Gi
          resources: {
            cpu: json('1.5')
            memory: '3Gi'
          }

          volumeMounts: [
            {
              volumeName: 'neo4j-data'
              mountPath: '/data'
            }
          ]
        }
      ]

      // Storage on the replica itself. It survives container restarts but not a new
      // replica; the graph is a copy of Databricks, so the loader job rebuilds it.
      volumes: [
        {
          name: 'neo4j-data'
          storageType: 'EmptyDir'
        }
      ]

      // A database must not scale to zero, and only one replica may own the data
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }

  dependsOn: [
    acrPull
  ]
}

// ---------- Graph loader: job that copies Databricks into Neo4j, then exits ----------

resource graphLoader 'Microsoft.App/jobs@2024-03-01' = {
  name: graphLoaderJobName
  location: location

  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentity.id}': {}
    }
  }

  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'

    configuration: {
      // Runs on the schedule, and can also be started by hand:
      // az containerapp job start --name <prefix>-graph-loader --resource-group <rg>
      triggerType: 'Schedule'
      scheduleTriggerConfig: {
        cronExpression: loaderSchedule
        parallelism: 1
        replicaCompletionCount: 1
      }
      replicaTimeout: 3600 // seconds
      replicaRetryLimit: 1

      registries: [
        {
          server: acr.properties.loginServer
          identity: pullIdentity.id
        }
      ]

      // NEO4J_AUTH -> secret "neo4j-auth", DATABRICKS_TOKEN -> "databricks-token", etc.
      secrets: [
        for item in items(graphEnv): {
          name: toLower(replace(item.key, '_', '-'))
          #disable-next-line use-secure-value-for-secure-inputs // value comes from the @secure() graphEnv param
          value: item.value
        }
      ]
    }

    template: {
      containers: [
        {
          name: 'graph-loader'
          image: '${acr.properties.loginServer}/${graphLoaderImage}'

          // Same as the "environment:" block of graph-loader in docker-compose.yml
          env: concat(graphSecretEnv, [
            {
              name: 'NEO4J_URI'
              value: 'bolt://${neo4j.name}:7687'
            }
            {
              name: 'GOLD_SCHEMA'
              value: goldSchema
            }
          ])

          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
        }
      ]
    }
  }

  dependsOn: [
    acrPull
  ]
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
    workloadProfileName: 'Consumption'

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
    workloadProfileName: 'Consumption'

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
output neo4jUri string = 'bolt://${neo4j.name}:7687'
