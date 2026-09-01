#!/usr/bin/env sh
# Seeds the httpbun route + a key-auth consumer via the Admin API.
# Idempotent: PUT (201 "created" first run, 200 "updated" after).
# curl runs inside the etcd container — the apisix image ships no curl/wget,
# and the network-internal path bypasses the OIDC gate on :8282.
set -e
cd "$(dirname "$0")"
KEY='admin-key-poc-apisix-9f3c2a71'
BASE='http://apisix:9180/apisix/admin'

req() {
  if [ $# -ge 3 ]; then
    docker compose exec -T etcd curl -s -w '\nHTTP %{http_code}\n' -X "$1" "$BASE/$2" \
      -H "X-API-KEY: $KEY" -H 'Content-Type: application/json' -d "$3"
  else
    docker compose exec -T etcd curl -s -w '\nHTTP %{http_code}\n' -X "$1" "$BASE/$2" -H "X-API-KEY: $KEY"
  fi
}

echo '== route =='
req PUT routes/httpbun-route '{"uri":"/httpbun/*","plugins":{"proxy-rewrite":{"regex_uri":["^/httpbun/(.*)","/$1"]}},"upstream":{"type":"roundrobin","nodes":{"httpbun:80":1}}}'
echo '== consumer =='
req PUT consumers '{"username":"poc-user","plugins":{"key-auth":{"key":"poc-api-key-5e1a7c"}}}'
echo '== verify =='
req GET routes/httpbun-route
req GET consumers/poc-user
