# API Gateway PoCs

> **Warning:** this entire repo is AI-generated experimental output. Do **not** spend effort
> re-running or re-verifying these gateways — the evaluation conclusions are already written
> down in each gateway's `README.md` (architecture, ports, findings, gotchas). Read those
> instead of repeating the work.

Four independent docker-compose PoCs comparing API gateways: each runs a gateway whose
management surface is OIDC-gated, with mock-oauth2-server as IdP, httpbun as demo upstream,
and an API-key-protected data plane.

| Directory  | Gateway                                             | Summary                                            |
| ---------- | --------------------------------------------------- | -------------------------------------------------- |
| `gravitee/` | Gravitee APIM 4.x CE (MongoDB)                      | Native OIDC console login, no oauth2-proxy          |
| `kong/`     | Kong OSS 3.9 DB-mode + Postgres                     | Manager/Admin API behind oauth2-proxy               |
| `tyk/`      | Tyk Gateway + Dashboard v5.14                       | Dashboard unlicensed                                |

For details, findings and gotchas see each subdirectory's `README.md`:
`gravitee/README.md`, `kong/README.md`, `tyk/README.md`.
