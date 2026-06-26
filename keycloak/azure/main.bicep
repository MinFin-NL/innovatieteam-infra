// ---------------------------------------------------------------------------
// Central Keycloak platform for the pilots, on Azure Container Apps.
//
// Provisions, in one resource group (rg-platform):
//   - User-assigned managed identity (pulls the image + reads Key Vault)
//   - Key Vault (admin password, db password — pilot client secrets go here too)
//   - PostgreSQL Flexible Server + 'keycloak' database
//   - Container Apps Environment
//   - Keycloak Container App (external HTTPS ingress, single replica)
//
// The Keycloak image is the custom one built from ../Dockerfile (it bakes the
// realm JSONs). Push it to ACR first, then pass acrName + keycloakImage.
//
// First deploy: leave keycloakHostname empty, read the keycloakFqdn output,
// then redeploy with keycloakHostname='https://<that-fqdn>' to pin the issuer.
// ---------------------------------------------------------------------------

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Short prefix used in resource names.')
param prefix string = 'platform'

@description('Existing Azure Container Registry name (without .azurecr.io) holding the Keycloak image.')
param acrName string

@description('Full image reference, e.g. myregistry.azurecr.io/keycloak:26.1')
param keycloakImage string

@description('Public https hostname for Keycloak. Empty on first deploy; set after you know the FQDN.')
param keycloakHostname string = ''

@description('Name of an existing Container Apps Environment to reuse (e.g. cae-invulhulp-inno-d). Empty = create a dedicated cae-${prefix}.')
param existingCaeName string = ''

@description('Name of the Keycloak Container App.')
param appName string = 'keycloak'

@description('Postgres admin username.')
param postgresAdminUser string = 'kcadmin'

@secure()
param keycloakAdminPassword string

@secure()
param postgresAdminPassword string

var kvName = 'kv-${prefix}-${uniqueString(resourceGroup().id)}'
var pgName = 'psql-${prefix}-${uniqueString(resourceGroup().id)}'

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-keycloak'
  location: location
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// Let the identity pull the Keycloak image from ACR.
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, uami.id, 'acrpull')
  scope: acr
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull
  }
}

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
  }
}

// Let the identity read secrets from Key Vault.
resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, uami.id, 'kvsecretsuser')
  scope: kv
  properties: {
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
  }
}

resource secAdmin 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'keycloak-admin-password'
  properties: { value: keycloakAdminPassword }
}

resource secDb 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: kv
  name: 'postgres-admin-password'
  properties: { value: postgresAdminPassword }
}

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: pgName
  location: location
  sku: { name: 'Standard_B1ms', tier: 'Burstable' }
  properties: {
    version: '16'
    administratorLogin: postgresAdminUser
    administratorLoginPassword: postgresAdminPassword
    storage: { storageSizeGB: 32 }
    backup: { backupRetentionDays: 7, geoRedundantBackup: 'Disabled' }
    highAvailability: { mode: 'Disabled' }
  }
}

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
  parent: pg
  name: 'keycloak'
}

// Allow Azure-internal services (the Container App) to reach Postgres.
// 0.0.0.0-0.0.0.0 is the documented "allow Azure services" rule, not the public internet.
resource pgFw 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
  parent: pg
  name: 'AllowAzureServices'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

// Reuse an existing Container Apps Environment (e.g. the invulhulp one) when
// existingCaeName is set; otherwise stand up a dedicated one. Either way a
// single CAE can host both internal (invulhulp) and external (Keycloak) apps.
resource existingCae 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (!empty(existingCaeName)) {
  name: existingCaeName
}

resource newCae 'Microsoft.App/managedEnvironments@2024-03-01' = if (empty(existingCaeName)) {
  name: 'cae-${prefix}'
  location: location
  properties: {}
}

var caeId = empty(existingCaeName) ? newCae.id : existingCae.id

// Hostname is conditional: strict + pinned once you know the FQDN; otherwise
// Keycloak derives it from the forwarded request headers (fine for first boot).
var hostnameEnv = empty(keycloakHostname) ? [
  { name: 'KC_HOSTNAME_STRICT', value: 'false' }
] : [
  { name: 'KC_HOSTNAME', value: keycloakHostname }
  { name: 'KC_HOSTNAME_STRICT', value: 'true' }
]

resource keycloak 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    managedEnvironmentId: caeId
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        traffic: [ { weight: 100, latestRevision: true } ]
      }
      registries: [
        { server: '${acrName}.azurecr.io', identity: uami.id }
      ]
      secrets: [
        { name: 'kc-admin-pw', keyVaultUrl: secAdmin.properties.secretUri, identity: uami.id }
        { name: 'db-pw', keyVaultUrl: secDb.properties.secretUri, identity: uami.id }
      ]
    }
    template: {
      containers: [
        {
          name: 'keycloak'
          image: keycloakImage
          command: [ '/opt/keycloak/bin/kc.sh' ]
          args: [ 'start', '--optimized', '--import-realm' ]
          resources: { cpu: json('1.0'), memory: '2Gi' }
          env: concat([
            { name: 'KC_DB', value: 'postgres' }
            { name: 'KC_DB_URL', value: 'jdbc:postgresql://${pg.properties.fullyQualifiedDomainName}:5432/keycloak?sslmode=require' }
            { name: 'KC_DB_USERNAME', value: postgresAdminUser }
            { name: 'KC_DB_PASSWORD', secretRef: 'db-pw' }
            { name: 'KC_BOOTSTRAP_ADMIN_USERNAME', value: 'admin' }
            { name: 'KC_BOOTSTRAP_ADMIN_PASSWORD', secretRef: 'kc-admin-pw' }
            // Container Apps terminates TLS at the ingress and forwards over HTTP.
            // Without xforwarded, Keycloak builds wrong issuer/redirect URLs.
            { name: 'KC_PROXY_HEADERS', value: 'xforwarded' }
            { name: 'KC_HTTP_ENABLED', value: 'true' }
            { name: 'KC_HEALTH_ENABLED', value: 'true' }
            { name: 'KC_METRICS_ENABLED', value: 'true' }
            // NLDS welcome page; login/account themes come from the imported realm.
            { name: 'KC_SPI_THEME_WELCOME_THEME', value: 'nl-design-system' }
          ], hostnameEnv)
          probes: [
            {
              type: 'Readiness'
              httpGet: { path: '/health/ready', port: 9000 }
              initialDelaySeconds: 30
              periodSeconds: 10
            }
            {
              type: 'Liveness'
              httpGet: { path: '/health/live', port: 9000 }
              initialDelaySeconds: 60
              periodSeconds: 30
            }
          ]
        }
      ]
      // Single replica on purpose: >1 replica needs JGroups cluster discovery +
      // sticky sessions or Keycloak's distributed cache breaks logins. Scale up
      // only after configuring clustering.
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

output keycloakFqdn string = keycloak.properties.configuration.ingress.fqdn
output keyVaultName string = kv.name
output postgresFqdn string = pg.properties.fullyQualifiedDomainName
