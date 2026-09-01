# Gravitee APIM 4.x — OIDC-gated Console POC

Gravitee APIM 4.12.18 (Community Edition) with **native OIDC login on the Console** —
no oauth2-proxy in front. Management API + Gateway on MongoDB 7 (stateless), mock-OAuth2-Server
as IdP, httpbun as upstream demo API. V4 proxy API created via the v2 Management API with a
keyless plan.

## 1. Architecture

```
                     host-published ports: 9082 / 8083(loopback) / 8084 / 8085 / 8110
                     (mongo, httpbun are internal only)

  browser ──► localhost:8084  APIM Console SPA ──(CORS: allow-origin :8084)──► localhost:8083  Management API ─┐
                    │  login: form (admin/admin) or "mockoidc" button                                         │
                    │                                                                                        │
                    │  OIDC flow (SPA-driven PKCE code flow)                                                 │
                    ▼                                                                                        ▼
            http://idp.localhost:8110  (mock-oauth2-server)                                   localhost:8083/management/v2
            (network alias idp.localhost on the compose net;                                   ── sync ──► mongo:27017
             extra_hosts host-gateway → host loopback:8110)
                    │
  curl / browser ──► localhost:9082  APIM Gateway ──► httpbun  (keyless plan)   ◄── syncs APIs from mongo directly

  browser ──► localhost:8085  Developer Portal SPA ──► localhost:8083/portal  (CORS default *, untouched)

  management-api ◄──► mongo:27017 (management repo + analytics=none)
```

## 2. How to run

```sh
cd gravitee
docker compose up -d
```

Wait until `docker compose ps` shows all healthy (management-api takes ~60s, gateway boots
in parallel — it does NOT wait for the management API, it syncs from mongo on its own).

Then seed the demo API:

```sh
./setup-api.sh
```

The script is fully re-runnable: existing API and Keyless plan are detected and reused,
so it completes cleanly even on a second run (mongo is stateless, no volume).

## 3. Ports

| Port | Exposed as | What |
|------|-----------|------|
| 9082 | open | APIM Gateway data plane → httpbun (keyless demo API `/httpbun`) |
| 8083 | loopback (127.0.0.1) only | Management API (v1 `/management` + v2 `/management/v2`). Loopback-bound because the console SPA (browser) calls it cross-origin; nothing external needs it |
| 8084 | open | APIM Console UI (OIDC/Basic gated by login) |
| 8085 | open | Developer Portal UI |
| 8110 | open | mock-oauth2-server IdP (`/default` issuer) |
| 18082 | internal | Gateway core service (`/_node/health`) |
| 18083 | internal | Management API core service (`/_node/health`) |
| 27017 | internal | MongoDB |

## 4. Login flow

1. Open http://localhost:8084 (Console). Login page offers the username/password form
   **and** a `mockoidc` SSO button (the SPA discovers IdPs via
   `GET /management/organizations/DEFAULT/social-identities`).
2. Click **mockoidc** → the SPA itself starts a PKCE code flow against the IdP
   (`client_id=gravitee`, redirect `http://localhost:8084`, scopes openid+email+profile)
   → the custom login form `idp/login.html` is served PRE-FILLED
   (username `dev`, claims JSON with `dev@example.com`) — just click **Sign-in**.
3. Code lands on `localhost:8084`, the SPA posts it to
   `POST /management/organizations/DEFAULT/auth/oauth2/mockoidc` (200), which exchanges it
   server-side at the IdP token endpoint, maps the user via `userMapping`
   (id=`sub`, email, firstname=`given_name`, lastname=`family_name`) and roles via
   `roleMapping` (see Finding c). You land in the Console as **Dev User (dev@example.com),
   Primary Owner** — full admin.
4. The Basic form (`admin` / `admin`) stays available — the memory provider MUST stay in
   `security.providers` (it also authenticates `setup-api.sh`).

Client pair: `gravitee` / `gravitee-secret` (mock-oauth2-server accepts any pair; this fixed
one is declared in the management API's oidc provider config).

**Uniform-port trick:** the IdP is published on host port 8110 and aliased `idp.localhost`
on the compose network with `SERVER_PORT=8110`. Browser → `http://idp.localhost:8110`
(RFC 6761 loopback), management-api container → same URL via `extra_hosts host-gateway` +
published port. One URL works from both worlds, so the config (tokenEndpoint etc.) has no
dual entries.

**Logout (as observed):** Sign Out clears the console session **and** redirects through the
IdP end-session endpoint — `userLogoutEndpoint` IS honored: (1) `POST
/management/organizations/DEFAULT/user/logout` → 200; (2) browser GET
`http://idp.localhost:8110/default/endsession?id_token_hint=<ID_TOKEN>&post_logout_redirect_uri=http%3A%2F%2Flocalhost%3A8084%23%21%2F_login`
→ 302, no confirmation screen (mock-oauth2-server accepts and redirects immediately);
(3) back at `http://localhost:8084/#!/_login`. Re-login ALWAYS re-shows the prefilled
form — `interactiveLogin: true` never sets an IdP session cookie, so no silent re-auth;
every login is a deterministic one-click.

Useful URLs:
- Discovery: http://idp.localhost:8110/default/.well-known/openid-configuration
- IdP debugger: http://localhost:8110/default/debugger

## 5. Verification

```sh
# data plane (after ./setup-api.sh)
curl -sf http://localhost:9082/httpbun/get | jq '{method, url}'

# IdP alive + discovery
curl -s http://localhost:8110/isalive
curl -s http://idp.localhost:8110/default/.well-known/openid-configuration | jq '{issuer, userinfo_endpoint, end_session_endpoint}'

# the PoC API exists (v2 list; the v1 list returns [] for v2-created APIs — see gotchas)
curl -su admin:admin http://localhost:8083/management/v2/organizations/DEFAULT/environments/DEFAULT/apis | jq '.data[].name'

# CORS pinned to the console origin
curl -s -X OPTIONS http://localhost:8083/management/organizations/DEFAULT/environments/DEFAULT/apis \
  -H 'Origin: http://localhost:8084' -H 'Access-Control-Request-Method: GET' -D - -o /dev/null | grep -i access-control

# stack health
cd gravitee && docker compose ps
```

Browser: open :8084 → mockoidc → Sign-in → Console shows "httpbun PoC API" under APIs.

## 6. Findings

**(a) Native OIDC Console login on Community Edition = YES — via `security.providers` in
gravitee.yml, license-free.** The declared provider (`type: oidc, id: mockoidc`) shows up as
an SSO button and the whole flow works (login, user creation, roleMapping → Primary Owner).
Two nuances discovered:
- **It is a social-identity-provider, not a Basic-auth provider.** At boot the management API
  logs `ERROR ... No authentication provider found for type: oidc` from
  `BasicSecurityConfigurerAdapter` (the form/Basic auth chain, which only supports
  memory/gravitee/ldap) — this is benign; the oidc provider still registers for the
  SPA-driven SSO chain (`POST .../auth/oauth2/mockoidc`). Expect that ERROR line; the stack
  is healthy.
- Contrast with the EE-gated **console-UI** OIDC creation (Organization Settings → IdPs →
  `apim-openid-connect-sso` ForbiddenFeatureException on CE): *declaring* IdPs in
  gravitee.yml costs nothing; *managing* them in the UI is Enterprise.

**(b) Exact CORS config used** — under the existing `http.api.management` key:

```yaml
http:
  api:
    management:
      cors: { allow-origin: http://localhost:8084 }
```

Preflight observed: `Access-Control-Allow-Origin: http://localhost:8084`,
`Access-Control-Allow-Credentials: true` (hardcoded, no config key), `Allow-Methods:
OPTIONS,GET,POST,PUT,DELETE,PATCH`, `Max-Age: 1728000`. There is **no `enabled` key** in 4.x —
presence of the block is enough. The `http.api.portal.cors` tree stays untouched (default `*`)
so the portal SPA on :8085 keeps working.

**(c) Exact roleMapping condition that worked** (double-quoted YAML scalar — avoids escaping
pain; userMapping is MANDATORY, omitting it NPEs at login):

```yaml
      roleMapping:
        - condition: "{#jsonPath(#profile, '$.email') == 'dev@example.com'}"
          roles: [ORGANIZATION:ADMIN, ENVIRONMENT:ADMIN]
```

**(d) oauth2-proxy fallback NOT needed.** What it would have covered: an OIDC gate in front
of :8083/:8084 for every HTTP client (kong/tyk PoC pattern). Redundant here because the
console ships native SSO consumption on CE, and the data plane is deliberately keyless.
It would also have added the classic CORS/preflight/cookie dance this PoC avoided.

**(e) idp.localhost resolution.** Native on Linux/Chrome (RFC 6761: `*.localhost` → loopback).
macOS users need the hosts fallback: `echo '127.0.0.1 idp.localhost' | sudo tee -a /etc/hosts`.
Containers: musl/Alpine special-cases `*.localhost` to loopback bypassing DNS, hence
`extra_hosts: idp.localhost:host-gateway` routing to the host's published 8110 (uniform-port
trick above).

**(f) Stateless.** `docker compose down` wipes everything (mongo runs without a volume).
Re-run `./setup-api.sh` after `up -d` to recreate the demo API.

## 7. Gotchas

- **The mounted `gravitee.yml` REPLACES the shipped config** — it does not merge. The file in
  `management-api/` is the full shipped 4.12.18 config with `# POC-EDIT` markers.
- **`/_node` is NOT on 8083/8082 in 4.x** — node services moved to the core HTTP service
  (`services.core.http`, ports 18083/18082, bound to localhost inside the container, Basic
  auth `admin:adminadmin`). Healthchecks target those with precomputed base64; busybox wget
  ignores `user:pass@` URLs, so use `--header 'Authorization: Basic ...'`.
- **Two different default passwords:** management API console auth is `admin:admin` (bcrypt in
  the memory provider), while the core-service auth is `admin:adminadmin` (shipped
  `services.core.http` config — `adminadmin` is the legacy core password).
- **No Elasticsearch:** `repositories.analytics.type: none` in management-api config AND
  `gravitee_reporters_elasticsearch_enabled=false` on the gateway — set both or the gateway
  complains; console Analytics pages stay disabled (harmless).
- **The gateway syncs APIs from mongo directly** (~5s after `_start`), no management-API
  dependency in compose. If the data plane 503s, check `docker compose logs gateway`.
- **Gateway needs BOTH mongo URIs** — `gravitee_management_mongodb_uri` and
  `gravitee_ratelimit_mongodb_uri` (the latter defaults to localhost and fails).
- **v1 vs v2 management API paths for v2-created (V4/FULLY_MANAGED) APIs:** plans and
  lifecycle must go through the v2 tree —
  `POST /management/v2/orgs/.../apis/{id}/plans`, `POST .../apis/{id}/plans/{planId}/_publish`,
  `POST .../apis/{id}/_start`. The v1 list endpoint (`GET /management/.../apis`) returns `[]`
  for these APIs even when running — use `GET /management/v2/.../apis` (response is
  `{data: [...]}`, not a bare array).
- **httpbun is distroless** (scratch Go image, no shell) → no in-container healthcheck possible.
- Images pinned by tag except httpbun (digest). Re-verify healthchecks if tags bump.
