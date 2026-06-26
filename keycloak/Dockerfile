# Production Keycloak image for Azure Container Apps (and the prod compose file).
#
# Two things this image does that the plain quay.io image can't:
#   1. `kc.sh build` — pre-builds the server with the Postgres provider + health
#      enabled, so the container starts with `start --optimized` (fast, no build
#      step at boot).
#   2. Bakes the per-pilot realm JSONs into /opt/keycloak/data/import, so
#      `--import-realm` actually has something to import. On Container Apps there
#      is no host folder to mount, so the realms must live in the image.
#
# Rebuild + redeploy this image whenever you add a realm (see make-pilot-realm.sh).

FROM quay.io/keycloak/keycloak:26.1 AS builder
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true
# NL Design System theme (MinBZK/keycloak-theme) — copied in before build so the
# optimized image already contains the theme provider.
COPY providers/ /opt/keycloak/providers/
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.1
COPY --from=builder /opt/keycloak/ /opt/keycloak/
# Bake every realms/*.json as a *template*. docker-entrypoint.sh renders them
# into data/import/ at boot (swapping the dev client secret for the injected
# FINDOCS_BFF_CLIENT_SECRET) before exec-ing kc.sh — the startup --import-realm
# path can't substitute env placeholders itself.
COPY realms/ /opt/keycloak/data/import-templates/
COPY docker-entrypoint.sh /opt/keycloak/docker-entrypoint.sh
ENTRYPOINT ["bash", "/opt/keycloak/docker-entrypoint.sh"]
