#!/usr/bin/env bash
set -euo pipefail

MAPI=http://localhost:8083/management
ADMIN_USER=admin
ADMIN_PASS=admin

AUTH="-u ${ADMIN_USER}:${ADMIN_PASS}"
ENVS="organizations/DEFAULT/environments/DEFAULT"

echo "==> Checking management API auth (${ADMIN_USER}:${ADMIN_PASS})"
APIS=$(curl -sf $AUTH "${MAPI}/v2/${ENVS}/apis")
echo "    auth OK"

echo "==> Creating V4 proxy API 'httpbun PoC API'"
API_ID=$(echo "$APIS" | jq -r '.data[] | select(.name=="httpbun PoC API") | .id' | head -1)
if [ -z "$API_ID" ]; then
  API_ID=$(curl -sf $AUTH -X POST \
    -H 'Content-Type: application/json' \
    "${MAPI}/v2/${ENVS}/apis" \
    -d '{
      "name": "httpbun PoC API",
      "apiVersion": "1.0.0",
      "definitionVersion": "V4",
      "type": "PROXY",
      "listeners": [
        {
          "type": "HTTP",
          "paths": [{"path": "/httpbun"}],
          "entrypoints": [{"type": "http-proxy"}]
        }
      ],
      "endpointGroups": [
        {
          "name": "default-group",
          "type": "http-proxy",
          "endpoints": [
            {"name": "default", "type": "http-proxy", "weight": 1, "inheritConfiguration": false,
             "configuration": {"target": "http://httpbun:80"}}
          ]
        }
      ]
    }' | jq -r '.id')
  echo "    created API id=${API_ID}"
else
  echo "    already exists, id=${API_ID}"
  STATE=$(echo "$APIS" | jq -r --arg id "$API_ID" '.data[] | select(.id==$id) | .state')
fi

echo "==> Creating Keyless plan"
PLANS=$(curl -sf $AUTH "${MAPI}/v2/${ENVS}/apis/${API_ID}/plans")
PLAN_ID=$(echo "$PLANS" | jq -r '.data[] | select(.name=="Keyless") | .id' | head -1)
if [ -z "$PLAN_ID" ]; then
  PLAN_ID=$(curl -sf $AUTH -X POST \
    -H 'Content-Type: application/json' \
    "${MAPI}/v2/${ENVS}/apis/${API_ID}/plans" \
    -d '{
      "definitionVersion": "V4",
      "name": "Keyless",
      "security": {"type": "KEY_LESS"},
      "mode": "STANDARD"
    }' | jq -r '.id')
  echo "    created plan id=${PLAN_ID}"

  echo "==> Publishing plan"
  curl -sf $AUTH -X POST "${MAPI}/v2/${ENVS}/apis/${API_ID}/plans/${PLAN_ID}/_publish" > /dev/null
  echo "    published"
else
  echo "    already exists, id=${PLAN_ID}"
fi

echo "==> Starting API"
if [ "${STATE:-}" = "STARTED" ]; then
  echo "    already started"
else
  curl -sf $AUTH -X POST "${MAPI}/v2/${ENVS}/apis/${API_ID}/_start" > /dev/null
  echo "    started"
fi

echo "==> Waiting 6s for gateway to sync from mongo"
sleep 6

echo "==> Data-plane check: curl http://localhost:9082/httpbun/get"
curl -sf http://localhost:9082/httpbun/get
echo
echo "==> setup complete"
