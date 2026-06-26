// ---------------------------------------------------------------------------
// Central Keycloak platform for the pilots, on Azure Container Apps.
//
// Provisions, in one resource group (rg-platform):
//   - User-assigned managed identity (pulls the image + reads Key Vault)
//   - Key Vault (admin password, db password — pilot client secrets go here too)
//   - PostgreSQL *container* app (internal TCP ingress, single replica)
//   - Container Apps Environment
//   - Keycloak Container App (external HTTPS ingress, single replica)
//
// Why a Postgres container instead of a managed Flexible Server: the CCoE
// "Allowed Resource Types" guardrail (assigned at mgmt group minfin-mg100)
// denies Microsoft.DBforPostgreSQL/flexibleServers — and also the Azure Files
// mount type (App/managedEnvironments/storages) and Sql firewall rules. With a
// non-VNet environment there's no in-policy durable DB option, so for the pilot
// Postgres runs as a container on an EmptyDir volume.
//
// !! EPHEMERAL DATA !!  EmptyDir lives only as long as the replica. A new
// revision (every deploy), a scale event, or platform maintenance gives Postgres
// a fresh, empty disk. Keycloak rebuilds its schema and re-imports the baked-in
// realms on each boot (--import-realm), so config-as-code survives — but
// runtime-created users and sessions do NOT. Fine for a demo, not for keeps.
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

@description('Name of an existing Container Apps Environment to reuse (e.g. cae-invulhulp-inno-d). Empty = create a dedicated cae-<prefix>.')
param existingCaeName string = ''

@description('Name of the Keycloak Container App.')
param appName string = 'keycloak'

@description('Name of the Postgres Container App. Keycloak reaches it at this name over the environment-internal network.')
param postgresAppName string = 'postgres'

@description('Postgres container image. Pulled from Docker Hub by default; point at an ACR mirror if you hit pull limits.')
param postgresImage string = 'postgres:16'

@description('Postgres admin username.')
param postgresAdminUser string = 'kcadmin'

@secure()
param keycloakAdminPassword string

@secure()
param postgresAdminPassword string

var kvName = 'kv-${prefix}-${uniqueString(resourceGroup().id)}'

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

// Postgres as a container, reachable only inside the environment over TCP:5432.
// The official image creates the user/db on first init from POSTGRES_*; the
// password comes from Key Vault via the shared managed identity. Data lives on
// an EmptyDir volume — ephemeral by design (see the header note).
resource postgres 'Microsoft.App/containerApps@2024-03-01' = {
  name: postgresAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    managedEnvironmentId: caeId
    configuration: {
      activeRevisionsMode: 'Single'
      // Internal TCP ingress: other apps in the environment connect to
      // '<postgresAppName>:5432'. Not reachable from the public internet.
      ingress: {
        external: false
        transport: 'tcp'
        targetPort: 5432
        exposedPort: 5432
        traffic: [ { weight: 100, latestRevision: true } ]
      }
      secrets: [
        { name: 'db-pw', keyVaultUrl: secDb.properties.secretUri, identity: uami.id }
      ]
    }
    template: {
      containers: [
        {
          name: 'postgres'
          image: postgresImage
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'POSTGRES_USER', value: postgresAdminUser }
            { name: 'POSTGRES_PASSWORD', secretRef: 'db-pw' }
            { name: 'POSTGRES_DB', value: 'keycloak' }
            // Keep PGDATA in a subdir of the mount so initdb owns a clean dir.
            { name: 'PGDATA', value: '/var/lib/postgresql/data/pgdata' }
          ]
          volumeMounts: [
            { volumeName: 'pgdata', mountPath: '/var/lib/postgresql/data' }
          ]
          probes: [
            { type: 'Liveness', tcpSocket: { port: 5432 }, initialDelaySeconds: 30, periodSeconds: 30 }
            { type: 'Readiness', tcpSocket: { port: 5432 }, initialDelaySeconds: 10, periodSeconds: 10 }
          ]
        }
      ]
      // EmptyDir = node-local scratch tied to the replica's lifetime.
      volumes: [
        { name: 'pgdata', storageType: 'EmptyDir' }
      ]
      // Exactly one replica, always on. >1 would each get a separate empty disk;
      // scale-to-zero would drop the database between requests.
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

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
            // Reach the Postgres container by its app name over the env-internal
            // network. sslmode=disable: the container serves plain TCP and the
            // traffic never leaves the environment.
            { name: 'KC_DB_URL', value: 'jdbc:postgresql://${postgres.name}:5432/keycloak?sslmode=disable' }
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
output postgresHost string = '${postgres.name}:5432'
