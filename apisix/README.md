# Apache APISIX — etcd-backed OIDC POC

APISIX 3.18.0 (etcd 3.5) with its built-in management UI at `/ui/` — the successor to the
retired `apache/apisix-dashboard` — OIDC-gated by oauth2-proxy; mock-oauth2-server as IdP;
httpbun as upstream demo API.

## 1. Architecture

```
                     host-published ports: 9080 / 9180 / 8180 / 8282
                     (2379, 4180 and the upstream are internal only)

  browser ──► localhost:8282  oauth2-proxy ──► apisix:9180  Admin API + built-in management UI /ui/
                        │
                        ▼
                 http://idp.localhost:8180 (mock-oauth2-server, /default issuer;
                 oauth2-proxy resolves idp.localhost via extra_hosts host-gateway →
                 host → published 8180; the browser resolves *.localhost → loopback
                 → same 8180, so the issuer derived from the Host header stays
                 consistent on both legs)

  curl ──────────► localhost:9080  APISIX data plane ──► httpbun   (open, no auth by design)

  docker compose exec etcd curl ──► apisix:9180 Admin API   (network-internal seeding,
                                                             bypasses the :8282 gate)

  etcd:2379 ◄── apisix (config store)
```

## 2. How to run

```sh
cd apisix
docker compose up -d
./init-routes.sh        # seeds route + consumer via Admin API; idempotent (PUT)
```

`init-routes.sh` runs `curl` inside the **etcd container** (the apisix image ships no
curl/wget) and reaches the Admin API on the internal network — it bypasses the OIDC gate.
First run returns `201 "created"`, re-runs `200 "updated"`.

## 3. Ports

| Port | Exposed as | What |
|------|-----------|------|
| 9080 | open | APISIX data plane → httpbun (no auth — PoC design) |
| 9180 | open ⚠ | Admin API + built-in management UI `/ui/` **direct, un-gated** (PoC risk) |
| 8282 | OIDC-gated | same Admin API + built-in management UI `/ui/` through oauth2-proxy |
| 8180 | open | mock-oauth2-server IdP (`/default` issuer, debugger at `/default/debugger`) |
| 2379 | internal | etcd |
| 4180 | internal | oauth2-proxy listener |
| 80 | internal | httpbun |

No Kong-style `strip_path` in APISIX — the equivalent implemented here is the
`proxy-rewrite` plugin's `regex_uri: ["^/httpbun/(.*)", "/$1"]` (see `init-routes.sh`).

## 4. Login flow

1. Open http://localhost:8282/ui/ → redirect to
   http://idp.localhost:8180/default/authorize.
2. The login form arrives **pre-filled** (username `dev@example.com`, claims
   `{"email":"dev@example.com"}`) — just click **Sign-in**. (An email is
   required — oauth2-proxy reads it from the ID token.) Pre-fill values live in
   `idp-login.html`.
3. Done — you land directly on live data. The APISIX admin key is **injected server-side**
   by oauth2-proxy into every request it forwards (alpha-config `injectRequestHeaders`);
   there is no key entry step and the first-load 401 no longer occurs.

Client pair `poc-client` / `poc-secret` (the IdP accepts ANY pair; this fixed one is for
the debugger). Discovery:
http://idp.localhost:8180/default/.well-known/openid-configuration — debugger:
http://localhost:8180/default/debugger.

`*.localhost` resolution: Linux/RFC 6761 resolves to loopback; fallback:
`echo '127.0.0.1 idp.localhost' | sudo tee -a /etc/hosts` (for tools that don't
resolve `*.localhost`).

**Parallel logins across the PoCs are fine.** This gate uses
`--cookie-name=apisix_oauth2_proxy`, so its cookies no longer collide with the kong/tyk
gates on localhost (host-scoped cookies ignore ports — only the cookie NAME matters, and
names are now per-stack).

## 5. Verification

```sh
cd apisix && docker compose ps          # etcd + apisix Up (healthy), others Up

# data plane (open by design)
curl -s http://localhost:9080/httpbun/get -H 'apikey: poc-api-key-5e1a7c'   # 200 echo
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9080/httpbun/get  # 200 unauth

# OIDC gate
curl -si http://localhost:8282/ui/ | head -1                                 # 302 → idp authorize
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8282/apisix/admin/routes  # 302 (blocked)

# after OIDC login: 200 with NO X-API-KEY header — the key is injected
curl -s -b <session-cookie-jar> -o /dev/null -w '%{http_code}\n' http://localhost:8282/apisix/admin/routes  # 200

# IdP alive
curl -s http://localhost:8180/isalive

# direct admin API — 200 WITHOUT any OIDC: the documented :9180 exposure
curl -si http://localhost:9180/apisix/admin/routes -H 'X-API-KEY: admin-key-poc-apisix-9f3c2a71' | head -1
```

## 6. Findings

**(a) Management UI: APISIX's built-in `/ui/` supersedes the old dashboard.** The
`apisix-dashboard` GitHub repo is NOT formally archived (`archived: false`, last push
2026-08-09) but produces NO independent releases anymore — only per-APISIX-release fixed
tags, dormant; APISIX 3.18 ships the **built-in management UI at `/ui/`** that this PoC
uses.

**(b) Historical: the old `apache/apisix-dashboard` image still works, but is not used here.**
`apache/apisix-dashboard:3.0.1-alpine` against the live stack (etcd `poc-apisix_default`
network, `conf.yaml`: listen 0.0.0.0:9000, endpoints `http://etcd:2379`, auth
admin/admin):
- starts cleanly, login page serves (200), JWT login with admin/admin works;
- **reads work**: it lists the live `httpbun-route` (it talks to **etcd directly**, so the
  custom APISIX admin key is irrelevant to it);
- **writes work** with object-form upstream nodes (`{"httpbun:80":1}` → created, visible
  via the APISIX Admin API); an array-form nodes payload (older format) **hangs** the
  dashboard API indefinitely instead of 400-ing;
- periodic benign `dial tcp 127.0.0.1:2379: connection refused` warnings in its logs
  (internal client retrying the default endpoint — does not affect reads/writes).
Functional against 3.18, but retired here: this PoC uses the built-in `/ui/` exclusively —
the old image was tested only to verify whether it remained viable.

**(c) Fallback coverage.** oauth2-proxy OIDC gate on :8282 covers the Admin REST API +
built-in management UI. The data plane :9080 is intentionally open. :9180 is published and
**un-gated** — documented, PoC-only.

**(d) Injected-key auth through the gate (verified live).** oauth2-proxy injects the
APISIX admin key server-side into every request it forwards (alpha-config
`injectRequestHeaders` → `X-API-KEY`, loaded from file). Through :8282 the session
cookie ALONE suffices — verified: no `X-API-KEY` header, an **empty** `X-API-KEY`
header, and a **bogus** `X-API-KEY` header all return **200**, because
`preserveRequestValue: false` strips/replaces any client-supplied value (spoofing
ineffective). The old requirement for a cookie + key combo is gone; the built-in UI
needs no Settings-key setup and no first-load 401 recovery.

**(e) httpbun `:latest@sha256:` form is broken** (image `latest` moved Aug 2026) — use
digest-only form. Note: `kong/docker-compose.yml` still carries the broken form.

**(f) Multi-user key isolation: the control plane is ONE shared admin identity.**
(i) The **data plane** (`key-auth` consumer key) is per-consumer and independent — API
callers each use their own key. (ii) The **control plane** is different: with injection,
every OIDC-authenticated user IS the admin — they can list (receiving plaintext keys via
GET), create, and delete ALL consumers and keys, and delete routes. So yes: multiple
users share the same keys and can delete each other's. (iii) The OSS Admin API has no
per-user RBAC. A second `admin_key` with role `viewer` is GET-only (writes →
401 "invalid method for role viewer") but still sees all keys in plaintext — it demotes
its holder, it does not partition the admin key.

## 7. Gotchas

- **allow_admin 0.0.0.0/0 + published 9180 = un-gated admin API/UI** — PoC only; never
  ship like this.
- **OIDC login = full admin (injected key)**: through :8282 the session cookie alone
  carries full admin power — oauth2-proxy injects the admin key into every forwarded
  request. Anyone who can authenticate at the IdP is admin — protect the IdP accordingly.
- **"Invalid state" / redirect loop after swapping stacks with old builds**: clear
  cookies for `localhost` — old default-named `_oauth2_proxy` cookies are ignored by
  this gate since the cookie-name change (`apisix_oauth2_proxy`, set above).
- **Data-plane header is `apikey`, NOT `X-API-KEY`** — `X-API-KEY` is the Admin API
  header; the data plane wants lowercase `apikey`.
- **bitnamilegacy/etcd**: `bitnami/etcd` has zero Docker Hub tags (Aug 2025 move to
  bitnamilegacy) — frozen images, no updates.
- **httpbun must be pinned digest-only** (`repo@sha256:...`); `:latest@sha256:` fails.
- **Upstream nodes weights are INTEGERS** (`{"httpbun:80": 1}`); object form
  `{"host":"httpbun","port":80,"weight":1}` → 400.
- **PUT not PATCH** for seeding: PUT replaces (idempotent 201→200); PATCH merges.
- **apisix image has no curl/wget and /bin/sh is dash** → route seeding runs curl in the
  etcd container; the healthcheck invokes **bash explicitly** (`CMD bash -c`) because
  `/dev/tcp` is a bashism that dash rejects (`cannot create /dev/tcp/...`).
- **Distroless images** (httpbun, oauth2-proxy, mock-oauth2-server) → no in-container
  healthchecks possible.
- **`*.localhost`**: RFC 6761 loopback on Linux; `/etc/hosts` fallback line above
  (oauth2-proxy resolves it via `extra_hosts: host-gateway`).
- **IdP login page is the custom `idp-login.html`** (mock-oauth2-server `loginPagePath`)
  — pre-fill values are hardcoded there; 6.0.2 has no query-param prefill (`?subject=`
  / `?claims=` are only echoed, and oauth2-proxy's `--login-url` is discarded when OIDC
  discovery runs). Edit the HTML to change pre-fill values.
- **Benign APISIX 3.18 startup error** about stream plugins: `failed to load plugin
  [syslog] err: ... lua_shared_dict "prometheus-cache" not configured` — ignorable; the
  HTTP plugins load fine.
- **key-auth plugin is loaded but NOT attached to the httpbun route** — the route is
  public by design; to enforce auth add `"key-auth":{}` to the route's `plugins`. The
  generated consumer key `poc-api-key-5e1a7c` works either way.
- **Admin API PUT responses echo `key-auth` keys encrypted-at-rest** (e.g.
  `qku5VImzYz…`) — normal APISIX `encrypt_fields` behavior, not corruption;
  GET/reads return plaintext.
- **A 404 from a key-auth route means auth passed** — with `key-auth` attached, a
  valid key against a nonexistent upstream path returns **404** (auth passed) while
  a bad key returns **401** — a 404 means check the upstream path, not the key.
- **`secretSource.value` (base64) is NOT decoded in v7.15.4** — it is sent literally;
  use `secretSource.fromFile` with a byte-exact file (no trailing newline, or the key
  corrupts silently → upstream 401 with clean logs).
- **alpha-config is officially experimental** — the structure may change without notice.
- **Conflicting classic flags FATAL alongside `--alpha-config`**: `--provider`,
  `--oidc-issuer-url`, `--client-id`, `--client-secret`, `--code-challenge-method`,
  `--http-address`, `--upstream` must NOT remain (startup FATA). But
  `--redirect-url`, `--cookie-*`, `--email-domain`, `--skip-provider-button` have no
  alpha equivalent and MUST stay as flags.
- **Cookie-secret format**: oauth2-proxy needs the secret to be 16/24/32 raw bytes —
  `openssl rand -base64 32` output (44 chars) is **rejected**; use `openssl rand -hex 16`
  (32 chars) or any 32-byte string. Regenerate with `openssl rand -hex 16` if needed.
- **All credentials in this repo are throwaway PoC secrets** (admin key, consumer key,
  client secret, cookie secret) committed in plain text — regenerate before any
  non-PoC use (`openssl rand -hex 16` / `openssl rand -base64 32`).
- **`insecureSkipNonce: true` in the alpha config is deliberate** (mock IdP PoC; oauth2-proxy converter default) — OIDC replay protection is relaxed; never carry this into a real deployment.
