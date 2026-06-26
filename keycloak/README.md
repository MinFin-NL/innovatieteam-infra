# Keycloak — shared SSO for pilots

Standalone Keycloak identity provider. It is **not** tied to the findocs app:
it has its own Postgres and its own Docker network (`keycloak-shared`). You can
`mv` this folder into its own git repo at any time and nothing breaks.

The idea: **one Keycloak, one realm per pilot.** findocs uses the `findocs`
realm; a next pilot gets its own realm (or just another client in this one).

## Run it

```bash
cd keycloak
cp .env.example .env        # optional; defaults are fine for local dev
docker compose up -d
```

- Admin console: <http://localhost:8081> — login `admin` / `admin`
- Realm `findocs` and a demo user are imported automatically on first start.
- Demo login for the app: **demo / demo**

The realm config lives in [`realms/findocs-realm.json`](realms/findocs-realm.json)
and is imported via `--import-realm`. Edit there + restart to change config as
code. (Changes made by hand in the admin console are **not** written back to
that file — export with `kc.sh export` if you want to capture them.)

## Theme — NL Design System

Login, account and welcome pages use the
[MinBZK/keycloak-theme](https://github.com/MinBZK/keycloak-theme) (NL Design
System / ROOS). It's a prebuilt provider JAR — no Node/Java build needed.

- The JAR lives in [`providers/`](providers/) and is named `nl-design-system`
  inside (`META-INF/keycloak-themes.json`).
- **Dev:** mounted at `/opt/keycloak/providers` via `docker-compose.yml`.
- **Prod:** `COPY`'d into the image *before* `kc.sh build` (see `Dockerfile`),
  so `start --optimized` ships with it.
- **login + account themes** are set per-realm in
  [`realms/findocs-realm.json`](realms/findocs-realm.json)
  (`loginTheme` / `accountTheme`). The theme ships **no email type**, so
  `emailTheme` stays `base`.
- **welcome page** can't be set per-realm; it's selected with
  `KC_SPI_THEME_WELCOME_THEME=nl-design-system` (set in all compose files +
  the Azure bicep).

⚠️ The per-realm theme keys only apply on a **first-time `--import-realm`**
(empty DB). On an already-imported realm, set them by hand:

```bash
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master --user admin --password admin
docker compose exec keycloak /opt/keycloak/bin/kcadm.sh update realms/findocs \
  -s loginTheme=nl-design-system -s accountTheme=nl-design-system
```

To upgrade the theme, replace the JAR in `providers/` with a newer release from
the repo and restart (dev) or rebuild the image (prod).

## How an app connects

Apps join the `keycloak-shared` network and talk to Keycloak server-to-server
at `http://keycloak:8080`; browsers use `http://localhost:8081`. The
`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` setting makes that dual-URL split work
(it avoids the "issuer mismatch" you otherwise hit behind Docker).

Each app needs a confidential client. For findocs that is `findocs-bff` with:

- Redirect URI: `http://localhost:8080/api/auth/callback` (and `:5173` for vite dev)
- Client secret: `dev-secret-change-me` (**change for anything real**)

## Adding a new pilot

1. Admin console → **Create realm** (or add a client to `findocs`).
2. Create a confidential client, set its redirect URI to that app's
   `/api/auth/callback`, copy the secret.
3. Point the app at `http://keycloak:8080/realms/<realm>/.well-known/openid-configuration`.

## Before production

- Run with `start` (not `start-dev`) behind TLS; set `KC_HOSTNAME` to the https URL.
- Real admin credentials + real client secrets via your secret store.
- Back up the `keycloak_db` volume.
- For Dutch-government production, align with the NL GOV OAuth/OIDC profile.
