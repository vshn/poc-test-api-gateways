# Tyk PoC — API gateway with OIDC-gated management surface

Docker compose stack: Tyk Gateway v5.14 (data plane, API-key auth) + Tyk Dashboard v5.14 (unlicensed — see Findings) + mock-oauth2-server IdP + oauth2-proxy gating the management surface (dashboard UI + gateway control API behind one login).

## Architecture

```
                  host
  :18080 ──────────────────► gateway:8080 ──► /httpbun/* ──► httpbun:80 (internal)
                                │  ▲
                   /tyk/* ──────┘  └── also reachable UNGATED on :18080
                                │
  :18082 ──► oauth2-proxy:4180 ─┤
                │ /*      ──────► dashboard:3000   (dashboard UI, license screen)
                │ /tyk/*  ──────► gateway:8080/tyk/ (control API)
                │
                └── login flow ──► idp.localhost:18081 ──► idp:8080
  :18081 ──────────────────► idp:8080 (mock-oauth2-server, issuer
                              http://idp.localhost:18081/default)
  :18083 ──────────────────► dashboard:3000 (direct, ungated)

  internal only: redis:6379, mongo:27017
```

- oauth2-proxy routes `/*` → dashboard:3000 and `/tyk/*` → gateway:8080/tyk/.
- gateway `/httpbun/*` → httpbun:80 (internal only).
- The gateway's `/tyk/*` control API is **also reachable UNGATED on :18080** (same listener as the data plane) — see Findings.

## Ports

| Host port | Service | Purpose |
|---|---|---|
| 18080 | gateway | Data plane (`/httpbun/*`) + control API (`/tyk/*`) |
| 18081 | idp | mock-oauth2-server (issuer `http://idp.localhost:18081/default`) |
| 18082 | oauth2-proxy | OIDC-gated management surface (dashboard + `/tyk/*`) |
| 18083 | dashboard | Direct, ungated — shows the license screen |

Deviation note: the task suggested 8082 for the gate; 8000/8080/8081/8082 are occupied by the Kong agent's stack on this host, so the 1808x range is used.

## Run

```
docker compose up -d
docker compose ps          # redis, mongo, idp must show (healthy)
curl -s localhost:18080/ready   # 200 once gateway has redis + APIs (poll a few seconds)
```

Healthchecks exist only where the image has tooling (redis-cli / mongosh / wget). Gateway, dashboard, oauth2-proxy, httpbun are distroless (no shell) → they show "running", not "healthy". Verify them from the host (commands below).

## OIDC login flow

1. Open http://localhost:18082/ → 302 straight to the IdP authorize URL (`http://idp.localhost:18081/default/authorize?client_id=tyk-poc&...`)
2. IdP login form: username `dev@example.com`, claims textarea `{"email":"dev@example.com"}` → Sign in
3. 302 back to `http://localhost:18082/oauth2/callback` → session cookie `_oauth2_proxy`
4. Authenticated: `/` serves the dashboard (license HTML); `/tyk/*` proxies to the gateway control API.

Client: id `tyk-poc`, secret `tyk-poc-secret` (mock IdP accepts anything).

### Why idp.localhost

The IdP derives its issuer from the Host header. Browser AND containers must see the same issuer, so every client uses `http://idp.localhost:18081`:

- Browser: resolves `*.localhost` → 127.0.0.1 (Chromium/Firefox do this natively). Fallback if a tool doesn't: `echo '127.0.0.1 idp.localhost' | sudo tee -a /etc/hosts`
- oauth2-proxy container: `extra_hosts: idp.localhost:host-gateway` → host IP → published port 18081 → idp container.
- Service-name access (`http://idp:8080`) would break issuer consistency (Host would be `idp:8080`) — do not use it.

## Verify

```
# 1. containers
docker compose ps

# 2. gateway data plane with an API key (create key first — see next section)
KEY=$(cat .generated-api-key)
curl -s -H "Authorization: $KEY" localhost:18080/httpbun/get | jq .
#    → 200, JSON echo (method GET, url http://httpbun/get — listen path stripped, upstream saw /get)
curl -s -o /dev/null -w '%{http_code}\n' localhost:18080/httpbun/get
#    → 401 (no key)

# 3. gate redirects unauthenticated requests
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' localhost:18082/
#    → 302 http://idp.localhost:18081/default/authorize?client_id=tyk-poc...

# 4. surfaces
curl -s localhost:18081/isalive           # "alive and well"
curl -s localhost:18082/ready             # "OK" (unauthenticated, by design)
curl -s localhost:18080/hello             # Tyk hello, 200
curl -s -o /dev/null -w '%{http_code}\n' localhost:18083/   # 200 license HTML
```

## Create an API key (through the OIDC gate)

Playwright (or any browser) on http://localhost:18082/ → complete the IdP login → then, in the same browser context (session cookie applies):

```js
fetch('/tyk/keys/create', {
  method: 'POST',
  headers: {'Content-Type': 'application/json',
            'X-Tyk-Authorization': '352d20ee67be67f6340b4c0605b044b7'},
  body: JSON.stringify({org_id: '1',
    access_rights: {httpbun: {api_name: 'httpbun', api_id: 'httpbun',
                              versions: ['Default']}}})
})
```

→ `{"action":"added","key":"...","key_hash":"..."}`. Persist `key` to `.generated-api-key` (gitignored), then use it as in Verify #2.

Debug shortcut (ungated, host → data-plane port): the control API shares :18080, so the same POST works directly against `localhost:18080` with the X-Tyk-Authorization header. Convenient for testing; see Findings.

## Findings

- **Dashboard is license-blocked.** It boots unlicensed and serves a license screen: every GET returns 200 license HTML; real API routes return 402 `{"Status":"Error","Message":"Not authorised"}`. No setup endpoint, nothing configurable. That is why keys are minted via the OSS gateway control API (`/tyk/keys/create`), which needs no license, and why the gate fronts both surfaces.
- **Native dashboard OIDC/SSO exists but is enterprise-only.** TIB v1.7.3 is embedded: POST `/api/sso` (60s nonce) → `/tap?nonce=`, config keys `sso_*` (env `TYK_DB_SSO*`). Unlicensed, `/api/sso` returns 402 (verified). Docs: https://tyk.io/docs/tyk-identity-broker/dashboard-sso . The oauth2-proxy gate is the working fallback and covers both UI and control API.
- **oauth2-proxy upstream routing gotcha:** an upstream path prefix MUST end with `/` to route sub-paths (`--upstream=http://gateway:8080/tyk/`). Without the trailing slash only the exact path `/tyk` matches and everything else 404s inside the proxy. Longest-prefix wins: `/tyk/*` goes to the gateway, everything else to the dashboard. The full original path is forwarded (verified: `/tyk/foo` arrives as `/tyk/foo`).
- **X-Tyk-Authorization passes through the gate** (oauth2-proxy only strips X-Forwarded-\* auth headers and Authorization). Send `Content-Type: application/json`.
- **Control API on the data-plane port.** `/tyk/*` is served on the same listener as `/httpbun/*` → ungated from the host on :18080. Fine for a PoC; production would set `control_api_hostname` or firewall it.
- **Stateless stack:** no volumes. API keys live in redis, dashboard data in mongo — both reset on `docker compose down`. Re-mint the key after a down/up.
- **Gateway log noise: `level=error message="Payload signature is invalid!" prefix=pub-sub`.** Dashboard-originated cluster notifications the gateway can't verify (no shared pub-sub secret configured). Benign in this PoC (file-based API defs; dashboard license-blocked). Silence it by not running the dashboard, or set a shared secret in production.
- **Cookie secret:** `--cookie-secret` is URL-safe base64 decoding to 32 bytes. Regenerate: `openssl rand -base64 32 | tr '+/' '-_'` and strip padding if you prefer (std-base64 with `+`/`/` FAILS — RawURLEncoding), update the compose file, restart oauth2-proxy (invalidates sessions).

## oauth2-proxy flags

| Flag | Why |
|---|---|
| `--provider=oidc`, `--oidc-issuer-url=http://idp.localhost:18081/default` | OIDC against mock IdP (issuer must match Host-derived issuer) |
| `--client-id`/`--client-secret`=tyk-poc / tyk-poc-secret | mock IdP accepts any |
| `--redirect-url=http://localhost:18082/oauth2/callback` | browser-visible gate URL |
| `--cookie-secret=`\<32-byte urlsafe b64\>, `--cookie-secure=false` | plain HTTP on localhost |
| `--email-domain=*` | allow any authenticated email (default denies all!) |
| `--skip-provider-button` | unauthenticated → 302 straight to IdP (else 403 sign-in page) |
| `--code-challenge-method=S256` | PKCE, supported by mock IdP |
| `--upstream=http://dashboard:3000` | catch-all (no path prefix) |
| `--upstream=http://gateway:8080/tyk/` | control API; trailing slash = prefix match |
| `extra_hosts` idp.localhost:host-gateway | issuer-consistent IdP reachability from container |

## Step: bring up and smoke-test

1. `mkdir -p apps` as needed; write files.
2. `cd /workspaces/api-gateways/tyk && docker compose up -d`
3. Wait for health: `docker compose ps` — expect redis, mongo, idp (healthy); others Up/running.
4. Poll `curl -s -o /dev/null -w '%{http_code}' localhost:18080/ready` until 200 (max ~60s).
5. Check `docker compose logs oauth2-proxy --tail 20` — no OIDC discovery errors; `docker compose logs gateway --tail 20` — "Detected 1 APIs".
6. Smoke: `curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' localhost:18082/` → expect `302 http://idp.localhost:18081/default/authorize?...`; `curl -s localhost:18080/httpbun/get` → 401 (needs key); `curl -s -o /dev/null -w '%{http_code}\n' localhost:18083/` → 200; `curl -s localhost:18081/isalive` → alive and well.
7. If any check fails, diagnose and FIX (don't leave broken): oauth2-proxy crash loop = host-gateway/idp.localhost resolution issue; 404 on `/tyk/*` via 18082 = upstream trailing slash; dashboard exit = mongo/redis config shape.
