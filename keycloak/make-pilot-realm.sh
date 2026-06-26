#!/usr/bin/env bash
#
# Clone the findocs realm into a new per-pilot realm with production URLs and a
# fresh client secret. Writes realms/<pilot>-realm.json — rebuild + redeploy the
# Keycloak image (./azure/deploy-platform.sh) so --import-realm picks it up, or
# import it live with kcadm.sh.
#
#   Usage: ./make-pilot-realm.sh <pilot-name> <https-app-domain>
#   e.g.   ./make-pilot-realm.sh pilot-a https://app.pilot-a.nl
#
# Requires: jq, openssl.
#
set -euo pipefail

PILOT=${1:?pilot name, e.g. pilot-a}
DOMAIN=${2:?app https domain, e.g. https://app.pilot-a.nl}
DOMAIN=${DOMAIN%/}   # strip trailing slash

command -v jq >/dev/null      || { echo "jq is required"; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/realms/findocs-realm.json"
OUT="$SCRIPT_DIR/realms/${PILOT}-realm.json"

if [[ -e "$OUT" ]]; then
  echo "Refusing to overwrite existing $OUT"; exit 1
fi

SECRET=$(openssl rand -hex 24)

jq \
  --arg realm  "$PILOT" \
  --arg client "${PILOT}-bff" \
  --arg cb     "${DOMAIN}/api/auth/callback" \
  --arg origin "$DOMAIN" \
  --arg logout "${DOMAIN}/*" \
  --arg secret "$SECRET" \
  '
  .realm = $realm
  | .displayName = $realm
  | .clients[0].clientId = $client
  | .clients[0].name = ($realm + " BFF")
  | .clients[0].description = ("Backend-for-Frontend confidential client for " + $realm + ".")
  | .clients[0].secret = $secret
  | .clients[0].redirectUris = [$cb]
  | .clients[0].webOrigins = [$origin]
  | .clients[0].attributes["post.logout.redirect.uris"] = $logout
  | .users = []
  ' "$TEMPLATE" > "$OUT"

echo "Wrote $OUT"
echo
echo "  realm:   $PILOT"
echo "  client:  ${PILOT}-bff"
echo "  secret:  $SECRET"
echo
echo "Store the secret in Key Vault (the pilot backend reads it as OIDC_CLIENT_SECRET):"
echo "  az keyvault secret set --vault-name <kv> --name ${PILOT}-oidc-secret --value $SECRET"
echo
echo "Then make Keycloak load the realm:"
echo "  ./azure/deploy-platform.sh          # rebuilds the image with the new realm baked in"
echo "  # or, live, without redeploy:"
echo "  kcadm.sh create realms -f $OUT"
echo
echo "No demo user is created. Add users via the admin console, kcadm, or a user-federation source."
