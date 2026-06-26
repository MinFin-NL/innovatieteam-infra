# Keycloak on Azure — central IdP for the pilots

How to run the standalone Keycloak (one realm per pilot) on **Azure Container
Apps**, with pilots living in **separate resource groups**. For local dev see
[README.md](README.md); this file is the production/Azure counterpart.

## The mental-model shift: resource groups aren't a network boundary

Locally, pilots reach Keycloak over the `keycloak-shared` Docker network at
`http://keycloak:8080`. **Azure has no equivalent of one Docker network spanning
resource groups.** A resource group is a billing/management boundary — it does
nothing to connect *or* isolate network traffic.

So "pilots in different resource groups" is really a *networking* question, and
we answered it with **public HTTPS**: Keycloak gets one public hostname, and
every pilot backend (in whatever RG) reaches it over the internet. OIDC is
designed for exactly this. (If you later want the IdP private, swap to VNet
peering / Private Endpoints — only the URLs change, not the app.)

This also removes a piece of local complexity. The dev stack needs
`KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` only because Docker exposes two hostnames
(`keycloak:8080` internal vs `localhost:8081` external). In Azure there is **one**
public hostname for both browsers and pilot backends, so issuer mismatch
disappears and that setting is dropped.

## Topology

```
┌─ rg-platform ──────────────────────────────┐
│  Container Apps Env: cae-platform           │
│   └─ keycloak  (external ingress, HTTPS)    │  https://keycloak.<env>.azurecontainerapps.io
│  Postgres Flexible Server  (Keycloak DB)    │   realms:  pilot-a, pilot-b, …
│  Key Vault  (admin pw, client secrets)      │
└─────────────────────────────────────────────┘
        ▲ public HTTPS (OIDC discovery + token)
        │
┌─ rg-pilot-a ─────────┐   ┌─ rg-pilot-b ─────────┐
│ cae-pilot-a          │   │ cae-pilot-b          │
│  ├─ backend (BFF)    │   │  ├─ backend (BFF)    │
│  └─ frontend         │   │  └─ frontend         │
│  realm: pilot-a      │   │  realm: pilot-b      │
└──────────────────────┘   └──────────────────────┘
```

**One central Keycloak, one realm per pilot.** Single thing to patch, back up,
and monitor; each pilot still gets isolated users/roles/login theme via its own
realm.

## What changes from the dev Keycloak (`docker-compose.yml`)

Three dev settings are wrong for Container Apps:

| Dev | Azure Container Apps |
|---|---|
| `start-dev` | `start --optimized` (prod mode, pre-built image) |
| `KC_HOSTNAME: http://localhost:8081` + `KC_HOSTNAME_BACKCHANNEL_DYNAMIC: true` | `KC_HOSTNAME: https://<fqdn>` — single public hostname, backchannel-dynamic dropped |
| *(none)* | `KC_PROXY_HEADERS: xforwarded` — **mandatory**; ingress terminates TLS and forwards over HTTP, so without it Keycloak builds wrong issuer/redirect URLs |
| Postgres container | Azure Database for PostgreSQL Flexible Server (`sslmode=require`) |
| secrets in `.env` | Key Vault → Container App secret refs |

### Two Container-Apps gotchas

1. **Pin Keycloak to a single replica** (`min=1, max=1`). Keycloak's Infinispan
   cache needs JGroups cluster discovery; Container Apps autoscaling would
   silently start a second replica and break logins/sessions. One replica avoids
   all clustering config. Scale up later only with proper JGroups + sticky
   sessions.
2. **Health probe → management port 9000.** `KC_HEALTH_ENABLED=true` serves
   `/health/ready` and `/health/live` on **9000**, not 8080.

### Why a custom image

Container Apps has no host folder to mount, so `--import-realm` finds nothing
unless the realm JSONs are **inside the image**. [`Dockerfile`](Dockerfile) runs
`kc.sh build` and copies `realms/` into `/opt/keycloak/data/import`. Rebuild +
redeploy whenever you add a realm.

## Files in this folder

| File | Purpose |
|---|---|
| [`Dockerfile`](Dockerfile) | Production Keycloak image: `kc.sh build` + bakes `realms/` |
| [`azure/main.bicep`](azure/main.bicep) | rg-platform: identity, Key Vault, Postgres, Container Apps Env, Keycloak app |
| [`azure/deploy-platform.sh`](azure/deploy-platform.sh) | Build/push the image + deploy the Bicep (manual / first-time) |
| [`azure-pipelines.yml`](azure-pipelines.yml) | Azure DevOps CI/CD: same two-pass deploy, on every push to `main` |
| [`make-pilot-realm.sh`](make-pilot-realm.sh) | Clone `findocs-realm.json` → a new pilot realm with prod URLs + fresh secret |
| [`docker-compose.azure.yml`](docker-compose.azure.yml) | Prod-mode compose (VM / local prod testing) |
| [`../.env.azure.example`](../.env.azure.example) | Pilot backend env vars (mirrors `auth.py`) |

## Deploy the platform

```bash
cd keycloak
export ACR=myregistry KC_ADMIN_PASSWORD=... PG_ADMIN_PASSWORD=...
./azure/deploy-platform.sh                       # 1st run — hostname not yet known
export KEYCLOAK_HOSTNAME=https://<keycloakFqdn-from-output>
./azure/deploy-platform.sh                       # 2nd run — pins the issuer (KC_HOSTNAME_STRICT)
```

The first run leaves `KC_HOSTNAME` unset (`KC_HOSTNAME_STRICT=false`), so
Keycloak derives the host from forwarded headers; the second run pins it once
you know the FQDN. (Add a custom domain on the Container App and use that for
`KEYCLOAK_HOSTNAME` if you don't want the `azurecontainerapps.io` name.)

## Deploy via Azure DevOps pipeline

[`azure-pipelines.yml`](azure-pipelines.yml) does the same thing as the script,
on every push to `main` that touches `keycloak/`. It deploys into the **same
resource group as invulhulp** (`rg-invulhulp-inno-d`): it reuses that ACR and
the existing Container Apps Environment (`cae-invulhulp-inno-d`), and names the
app `ca-keycloak-inno-d`, per the `ca-{service}-inno-d` convention. The Bicep
still creates Keycloak's own Key Vault + Postgres in that RG.

One-time setup:

1. Variable group **`invulhulp-secrets`** already provides
   `AZURE_SERVICE_CONNECTION` — reused as-is.
2. Create variable group **`keycloak-secrets`** (Pipelines → Library) with
   `KC_ADMIN_PASSWORD` (secret) and `PG_ADMIN_PASSWORD` (secret).
3. New pipeline → point it at `keycloak/azure-pipelines.yml`.

The pipeline `az acr build`s the image (no Docker on the agent), then runs the
Bicep twice — once to learn the FQDN, once to pin it (`KC_HOSTNAME_STRICT`) —
exactly the two passes `deploy-platform.sh` does by hand. Keycloak shares the
CAE but keeps **external** ingress and a single replica; invulhulp's apps are
unaffected.

> The standalone `rg-platform` topology below is still supported by the Bicep
> (leave `existingCaeName` empty to get a dedicated `cae-${prefix}`). The
> pipeline just co-locates with invulhulp to reuse one ACR + environment.

## Onboard a pilot

```bash
# 1. Create the realm definition (writes realms/pilot-a-realm.json, prints a secret)
./make-pilot-realm.sh pilot-a https://app.pilot-a.nl

# 2. Store that secret + a session secret in Key Vault
az keyvault secret set --vault-name <kv> --name pilot-a-oidc-secret    --value <printed-secret>
az keyvault secret set --vault-name <kv> --name pilot-a-session-secret --value "$(openssl rand -hex 32)"

# 3. Make Keycloak load the realm (rebuilds the image with it baked in)
./azure/deploy-platform.sh
#    …or import live without redeploy:  kcadm.sh create realms -f realms/pilot-a-realm.json

# 4. Deploy the pilot's backend+frontend in rg-pilot-a, env from ../.env.azure.example
#    (OIDC_DISCOVERY_URL → .../realms/pilot-a/..., OIDC_CLIENT_ID=pilot-a-bff,
#     secrets as Key Vault refs, SESSION_HTTPS_ONLY=true).
```

## Realm lifecycle — decide early

`--import-realm` only imports a realm **if it doesn't already exist**; it won't
update one. Fine for bootstrapping. Once you have 3+ pilots, move realms to
real config-as-code — the **Terraform Keycloak provider** or `kcadm.sh`
scripts — so changes are reproducible instead of hand-edited in the admin
console.

## Before production

- Real admin + per-pilot client secrets in Key Vault (never `dev-secret-change-me`).
- TLS everywhere; `SESSION_HTTPS_ONLY=true` on every pilot backend.
- Back up the Postgres Flexible Server (point-in-time restore is on by default).
- For Dutch-government production, align with the NL GOV OAuth/OIDC profile.
