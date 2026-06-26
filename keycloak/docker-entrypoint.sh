#!/usr/bin/env bash
#
# Keycloak entrypoint that renders the baked realm templates before starting.
#
# Why: the realm JSONs are imported via `start --import-realm`, and that startup
# import path does NOT substitute ${ENV} placeholders (only the standalone
# `kc.sh import` subcommand does — see keycloak/keycloak#12069, #20199). So we
# render here instead: each template in data/import-templates/ is copied into
# data/import/ with two substitutions, then handed to kc.sh:
#
#   - 'dev-secret-change-me' -> $FINDOCS_BFF_CLIENT_SECRET (the findocs-bff secret)
#   - '__PUBLIC_URL__'       -> $PUBLIC_URL (the invulhulp frontend URL used in the
#                               realm's redirect URIs / web origins / logout URIs)
#
# When an env var is unset (e.g. local dev) that substitution is skipped and the
# template passes through unchanged. The dev secret stays literal — which is what
# lets the plain-image dev compose (no entrypoint, direct ./realms mount) work as
# is — and the __PUBLIC_URL__ sentinel simply sits unused next to the localhost
# entries that dev actually uses.
set -euo pipefail

# Bash 5.2+ makes '&' in a ${//} replacement expand to the matched text. Turn
# that off so values are inserted verbatim. (Use a base64/hex secret: a raw
# '"' or '\' would still break the JSON string regardless.)
shopt -u patsub_replacement 2>/dev/null || true

TPL_DIR=/opt/keycloak/data/import-templates
OUT_DIR=/opt/keycloak/data/import
DEV_SECRET='dev-secret-change-me'
URL_PLACEHOLDER='__PUBLIC_URL__'

if [[ -d "$TPL_DIR" ]]; then
  mkdir -p "$OUT_DIR"
  shopt -s nullglob
  for tpl in "$TPL_DIR"/*.json; do
    content="$(cat "$tpl")"

    if [[ -n "${FINDOCS_BFF_CLIENT_SECRET:-}" ]]; then
      # Bash pattern substitution: literal match, literal replacement.
      content="${content//"$DEV_SECRET"/$FINDOCS_BFF_CLIENT_SECRET}"
    else
      echo "[entrypoint] WARNING: FINDOCS_BFF_CLIENT_SECRET is not set; importing realm with the dev placeholder secret." >&2
    fi

    if [[ -n "${PUBLIC_URL:-}" ]]; then
      content="${content//"$URL_PLACEHOLDER"/$PUBLIC_URL}"
    else
      echo "[entrypoint] WARNING: PUBLIC_URL is not set; realm keeps the $URL_PLACEHOLDER placeholder (fine for local dev, which uses the localhost entries)." >&2
    fi

    printf '%s' "$content" > "$OUT_DIR/$(basename "$tpl")"
  done
fi

exec /opt/keycloak/bin/kc.sh "$@"
