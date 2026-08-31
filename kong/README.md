# Kong Gateway — Postgres-backed OIDC POC

Kong OSS 3.9.3 in DB mode (Postgres 16.9), Kong Manager and Admin API gated by
oauth2-proxy (OIDC) in front, mock-OAuth2-Server as IdP, httpbun as upstream demo API.

## 1. Architecture

```
                     host-published ports: 8000 / 8080 / 8081 / 8082
                     (8001, 8002 and postgres are internal only)

  browser ──► localhost:8082  oauth2-proxy (manager) ──► kong:8002  Kong Manager UI  ┐
                                             │                                      │ Kong
  browser SPA on :8082 ──► localhost:8081  oauth2-proxy (admin) ──► kong:8001 Admin API ┘ (postgres-backed)
                                             │
                                             ▼
                     http://idp.localhost:8080 (mock-oauth2-server)
                     (extra_hosts host-gateway → host loopback:8080;
                      network alias idp.localhost also on the compose net)

  curl / browser ──► localhost:8000  Kong proxy ──► httpbun  (key-auth demo, anonymous fallback)

  postgres (pgdata volume) ◄── kong-bootstrap (one-shot: schema + seed kong.yml)
```

## 2. How to run

```sh
cd kong
docker compose up -d
```

First run: `kong-bootstrap` creates the schema and seeds `kong.yml` into Postgres.
Reset to a clean slate: `docker compose down -v` (drops the `pgdata` volume), then `up -d` again.
Wait until `docker compose ps` shows postgres/kong/idp healthy (first boot takes ~30s) before verifying.

**`kong.yml` is a SEED.** Changes made via Kong Manager UI or the Admin API persist in the
`pgdata` volume. Editing `kong.yml` after the first import does **not** re-seed anything
(`kong config db_import` is not idempotent — re-runs are skipped with a WARN).

## 3. Ports

| Port | Exposed as | What |
|------|-----------|------|
| 8000 | open | Kong proxy → httpbun (key-auth demo) |
| 8080 | open | mock-oauth2-server IdP (`/default` issuer, debugger at `/default/debugger`) |
| 8081 | OIDC-gated | Admin API via oauth2-proxy (upstream kong:8001) |
| 8082 | OIDC-gated | Kong Manager via oauth2-proxy (upstream kong:8002) |
| 8001 | internal | Kong Admin API (raw) |
| 8002 | internal | Kong Manager (raw) |
| 5432 | internal | Postgres |

## 4. Login flow

1. Open http://localhost:8082 (Manager) or http://localhost:8081 (Admin API).
2. Redirect to the IdP login form (issuer: `http://idp.localhost:8080/default`).
   Client pair: `kong-manager` / `poc-secret` (the IdP accepts ANY pair; this fixed
   one is for the debugger).
3. Enter any username and claims JSON: `{"email":"dev@example.com"}` — an **email is
   required**: oauth2-proxy reads it from the ID token.
4. Done — you are logged in on **both** ports. Both oauth2-proxy instances share the
   same `--cookie-secret`, and the `_oauth2_proxy` cookie is host-scoped (`localhost`),
   not port-scoped.

Useful URLs:
- Debugger/playground: http://localhost:8080/default/debugger
- Discovery: http://idp.localhost:8080/default/.well-known/openid-configuration

**Log in sequentially (one tab at a time).** Parallel in-flight logins collide on the
shared host-scoped CSRF cookie; a retry resolves it.

## 5. Verification

```sh
# key-auth demo on the proxy
curl -si http://localhost:8000/httpbun/get | grep -Ei "HTTP/|X-Anonymous-Consumer"
curl -si http://localhost:8000/httpbun/get -H 'apikey: poc-test-key-123' | grep -Ei "HTTP/|X-Consumer-Username"

# OIDC gates
curl -si http://localhost:8082 | head -1        # → 302 to idp.localhost authorize
curl -si http://localhost:8081 | head -1        # → 302

# IdP alive
curl -s http://localhost:8080/isalive

# stack health
cd kong && docker compose ps
```

## 6. Findings

**Native OIDC for Kong Manager in OSS = NO.** Evidence:
- Admin API `/` `available_on_server` plugin list has no `openid-connect`.
- Image dir `/usr/local/share/lua/5.1/kong/plugins` has no `openid-connect`.
- docs.konghq.com/hub/kong-inc/openid-connect/ is marked `tier: enterprise`.
- Additionally `admin_gui_auth` / `admin_gui_session_conf` are EE-only (absent from OSS
  `kong.conf.default`) → **OSS Kong Manager has no built-in auth at all**, so
  oauth2-proxy is the sole gate.

What the fallback covers: OIDC gate on **both** Manager (:8082) and Admin API (:8081);
one shared-cookie login; data plane :8000 unauthenticated (key-auth demo with anonymous
fallback).

**Why Postgres:** DB-less Admin API is read-only — `POST /consumers` → `405`
"operation unsupported" (verified), and per Kong docs "You cannot create, update, or
delete entities with Kong Manager" in DB-less. DB mode makes Manager key creation work.

UI recipe that needs this: Manager (:8082) → Consumers → create a consumer (e.g.
`ui-created-consumer`) → Credentials → New Key Auth Credential → save the generated key
(Manager's Admin API is writable in DB mode; in DB-less it is read-only).

## 7. Gotchas

- **key-auth + anonymous**: a missing or INVALID key passes as the anonymous consumer
  (no 401) — by design; the route is public but attributed (`X-Anonymous-Consumer: true`).
- **httpbun** is distroless (no shell) → no in-container healthcheck
  ("exec sh: executable file not found").
- **oauth2-proxy v7.15.4 image** is distroless too → no healthcheck either.
- **kong image has no curl/wget** → use `kong health` in the healthcheck.
- `KONG_ADMIN_LISTEN` must be `0.0.0.0:8001` **explicitly** — image default is `127.0.0.1:8001`.
- `KONG_ADMIN_GUI_URL`/`KONG_ADMIN_GUI_API_URL` must be `:8082`/`:8081`, else the Manager
  SPA calls the unpublished `:8001`.
- `*.localhost` resolution: Linux/RFC 6761 resolves to loopback; fallback:
  `echo '127.0.0.1 idp.localhost' | sudo tee -a /etc/hosts`.
- `/etc/hosts` (`extra_hosts`) **shadows** the compose network alias. Only the two
  oauth2-proxy instances have `extra_hosts`; kong intentionally not (it never calls the
  IdP — the proxies do).
- musl/Alpine containers special-case `*.localhost` to loopback, bypassing DNS.
- `kong migrations bootstrap` re-run is safe ("Database already bootstrapped", exit 0);
  `kong config db_import` is NOT idempotent (guarded with `|| echo WARN`).
- `POST /config` reload on 3.9.3 needs `Content-Type: application/yaml` + `--data-binary`
  (multipart → 400).
- Images pinned by tag, except httpbun (digest). Re-verify healthchecks if tags bump.
- **cookie-secret format**: the shared secret hardcoded in docker-compose.yml was generated with
  `openssl rand -hex 16` — openssl is NOT a reproduction prerequisite. PITFALL:
  `openssl rand -base64 32` (44 chars incl. padding/punctuation) makes oauth2-proxy v7.15.4
  crash-loop with `cookie_secret must be 16, 24, or 32 bytes to create an AES cipher, but is 44
  bytes` — it only accepts raw 16/24/32 bytes or unpadded base64 decoding to that. If rotating,
  use `openssl rand -hex 16` (or `-base64 24`/`-base64 32` only if you strip padding).
- **oauth2-proxy answers 401 (not 302) for XHR/API-style unauthenticated requests** (no redirect,
  by design); browsers/curl without cookies get 302 to the IdP — expect both when testing.
- **Kong Manager Overview page may show `--` placeholders**: the SPA's initial app-config XHR to
  the Admin API (:8081) is sent WITHOUT credentials (fetch same-origin mode) → oauth2-proxy 401s
  it (no redirect, by design) → the 401 carries no CORS headers (never reaches Kong) → browser
  blocks it. Data-page XHRs (Consumers/Routes/…) DO carry the `_oauth2_proxy` cookie → 200 +
  Kong's built-in CORS → render fine. A complete fix needs same-origin routing for UI+API
  (compose redesign) — out of scope for this POC.
- **Port sharing across parallel POC stacks**: this stack publishes 8000/8080/8081/8082 — parallel
  stacks (e.g. apisix, which also uses 8080+8082) will conflict: affected containers fail to bind
  and exit. Run one stack at a time, or remap the host side of the port mappings. Recovery after
  the conflict clears: `docker compose up -d` from `kong/`.
