#!/usr/bin/env bash
#
# Deploy the central Keycloak platform (rg-platform) to Azure Container Apps.
# Run from the keycloak/ directory.
#
#   Required env:
#     ACR                 ACR name without .azurecr.io (must already exist)
#     KC_ADMIN_PASSWORD   Keycloak admin password
#     PG_ADMIN_PASSWORD   Postgres admin password
#   Optional env:
#     RG                  resource group     (default: rg-platform)
#     LOCATION            region             (default: westeurope)
#     KEYCLOAK_HOSTNAME   https URL to pin    (empty on first deploy)
#
# Usage:
#   export ACR=myregistry KC_ADMIN_PASSWORD=... PG_ADMIN_PASSWORD=...
#   ./azure/deploy-platform.sh                 # 1st run: leave KEYCLOAK_HOSTNAME empty
#   export KEYCLOAK_HOSTNAME=https://<fqdn-from-output>
#   ./azure/deploy-platform.sh                 # 2nd run: pins the issuer
#
set -euo pipefail

RG=${RG:-rg-platform}
LOCATION=${LOCATION:-westeurope}
: "${ACR:?Set ACR to your container registry name (without .azurecr.io)}"
: "${KC_ADMIN_PASSWORD:?Set KC_ADMIN_PASSWORD}"
: "${PG_ADMIN_PASSWORD:?Set PG_ADMIN_PASSWORD}"
HOSTNAME=${KEYCLOAK_HOSTNAME:-}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."   # keycloak/  — so Dockerfile + realms/ are the build context

echo "==> Resource group $RG ($LOCATION)"
az group create -n "$RG" -l "$LOCATION" -o none

echo "==> Building + pushing custom Keycloak image (bakes realms/)"
az acr build -r "$ACR" -t keycloak:26.1 -f Dockerfile .

echo "==> Deploying infra + Keycloak"
az deployment group create -g "$RG" -n keycloak-platform -f azure/main.bicep \
  -p acrName="$ACR" \
     keycloakImage="${ACR}.azurecr.io/keycloak:26.1" \
     keycloakHostname="$HOSTNAME" \
     keycloakAdminPassword="$KC_ADMIN_PASSWORD" \
     postgresAdminPassword="$PG_ADMIN_PASSWORD" \
  -o none

FQDN=$(az deployment group show -g "$RG" -n keycloak-platform \
        --query properties.outputs.keycloakFqdn.value -o tsv)
echo
echo "Keycloak FQDN: https://$FQDN"
if [[ -z "$HOSTNAME" ]]; then
  echo "Next: export KEYCLOAK_HOSTNAME=https://$FQDN  and re-run to pin the issuer."
fi
