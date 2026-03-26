#!/bin/bash
set -euo pipefail

# Usage:
#   ./configure-clients.sh <public-hostname> <admin-password> <kiali-hostname> <jaeger-hostname>
#
# This script should be run ON THE SAME SERVER as Keycloak.
# It uses http://localhost:8080 for API calls, public hostname only for redirect URIs.

PUBLIC_HOSTNAME="${1:?Usage: $0 <keycloak-public-hostname> <admin-password> <kiali-hostname> <jaeger-hostname>}"
ADMIN_PASSWORD="${2:?Usage: $0 <keycloak-public-hostname> <admin-password> <kiali-hostname> <jaeger-hostname>}"
KIALI_HOSTNAME="${3:?Usage: $0 <keycloak-public-hostname> <admin-password> <kiali-hostname> <jaeger-hostname>}"
JAEGER_HOSTNAME="${4:?Usage: $0 <keycloak-public-hostname> <admin-password> <kiali-hostname> <jaeger-hostname>}"

# API calls go to localhost (HTTP), public URL used only in redirect URIs
KEYCLOAK_API="http://localhost:8080"

REALM="istio"

echo "=== Configuring Keycloak ==="
echo "    API:    ${KEYCLOAK_API}"
echo "    Public: https://${PUBLIC_HOSTNAME}"

echo "--- Checking Keycloak health..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${KEYCLOAK_API}/health/ready" || echo "000")
if [ "$HTTP_STATUS" = "200" ]; then
  echo "OK (Keycloak is healthy)"
else
  echo "WARNING: Health check returned HTTP ${HTTP_STATUS}, trying to continue..."
fi

echo "--- Getting admin token..."
TOKEN_RESPONSE=$(curl -s -X POST "${KEYCLOAK_API}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=${ADMIN_PASSWORD}")

if [ -z "$TOKEN_RESPONSE" ]; then
  echo "ERROR: Empty response from Keycloak token endpoint."
  echo "       Check if Keycloak is running: systemctl status keycloak"
  echo "       Check logs: journalctl -u keycloak -n 50"
  exit 1
fi

TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    if 'access_token' in data:
        print(data['access_token'])
    else:
        print('ERROR: ' + str(data), file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print('ERROR parsing response: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1) || { echo "ERROR: Could not get token. Response: $TOKEN_RESPONSE"; exit 1; }

echo "OK (token received)"

kc_api() {
  local method="$1" path="$2" data="${3:-}"
  local url="${KEYCLOAK_API}/admin/realms${path}"
  if [ -n "$data" ]; then
    curl -s -o /dev/null -w "%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$data"
  else
    curl -s -o /dev/null -w "%{http_code}" -X "$method" "$url" \
      -H "Authorization: Bearer ${TOKEN}"
  fi
}

kc_get() {
  local path="$1"
  curl -s -X GET "${KEYCLOAK_API}/admin/realms${path}" \
    -H "Authorization: Bearer ${TOKEN}"
}

echo "--- Creating realm: ${REALM}"
STATUS=$(kc_api POST "" "{\"realm\":\"${REALM}\",\"enabled\":true,\"displayName\":\"Istio\"}")
if [ "$STATUS" = "201" ]; then
  echo "OK (created)"
elif [ "$STATUS" = "409" ]; then
  echo "OK (already exists)"
else
  echo "WARNING: HTTP $STATUS"
fi

create_client() {
  local client_id="$1" redirect_uri="$2" description="$3"
  echo "--- Creating client: ${client_id}"

  STATUS=$(kc_api POST "/${REALM}/clients" "{
    \"clientId\": \"${client_id}\",
    \"enabled\": true,
    \"description\": \"${description}\",
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"standardFlowEnabled\": true,
    \"directAccessGrantsEnabled\": false,
    \"redirectUris\": [\"${redirect_uri}\"],
    \"webOrigins\": [\"+\"]
  }")

  if [ "$STATUS" = "201" ]; then
    echo "OK (created)"
  elif [ "$STATUS" = "409" ]; then
    echo "OK (already exists)"
  else
    echo "WARNING: HTTP $STATUS"
  fi

  local client_uuid
  client_uuid=$(kc_get "/${REALM}/clients?clientId=${client_id}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('ERROR: client not found', file=sys.stderr)
    sys.exit(1)
print(data[0]['id'])
")

  local client_secret
  client_secret=$(kc_get "/${REALM}/clients/${client_uuid}/client-secret" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('value', 'N/A'))
")

  echo "  Client ID:      ${client_id}"
  echo "  Client Secret:  ${client_secret}"
  echo ""
  export "SECRET_${client_id//-/_}=${client_secret}"
}

create_client "kiali" "https://${KIALI_HOSTNAME}/*" "Kiali Service Mesh Dashboard"
create_client "jaeger-proxy" "https://${JAEGER_HOSTNAME}/oauth2/callback" "OAuth2 Proxy for Jaeger"

echo "--- Creating user: viewer"
STATUS=$(kc_api POST "/${REALM}/users" "{
  \"username\": \"viewer\",
  \"enabled\": true,
  \"email\": \"viewer@easysolution.work\",
  \"credentials\": [{\"type\": \"password\", \"value\": \"viewer123\", \"temporary\": false}]
}")
if [ "$STATUS" = "201" ]; then
  echo "OK (created)"
elif [ "$STATUS" = "409" ]; then
  echo "OK (already exists)"
else
  echo "WARNING: HTTP $STATUS"
fi

COOKIE_SECRET=$(python3 -c "import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())")

echo ""
echo "=== Done ==="
echo ""
echo "Realm:    ${REALM}"
echo "Issuer:   https://${PUBLIC_HOSTNAME}/realms/${REALM}"
echo ""

VAULT_ADDR="${VAULT_ADDR:-https://vault.easysolution.work}"
VAULT_SECRET_PATH="${VAULT_ADDR}/v1/secret/data/istio/keycloak"

if [ -n "${VAULT_TOKEN:-}" ]; then
  echo "--- Writing secrets to Vault (${VAULT_SECRET_PATH})..."
  VAULT_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" -X PUT "${VAULT_SECRET_PATH}" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
      \"data\": {
        \"jaeger-client-secret\": \"${SECRET_jaeger_proxy:-}\",
        \"oauth2-proxy-cookie-secret\": \"${COOKIE_SECRET}\"
      }
    }")
  if [ "$VAULT_STATUS" = "200" ] || [ "$VAULT_STATUS" = "204" ]; then
    echo "OK (secrets written to Vault)"
  else
    echo "WARNING: Vault returned HTTP ${VAULT_STATUS}"
    VAULT_TOKEN=""
  fi
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "VAULT_TOKEN not set. Run this command manually to save secrets:"
  echo ""
  echo "  export VAULT_TOKEN=<your-vault-token>"
  echo "  curl -sk -X PUT ${VAULT_SECRET_PATH} \\"
  echo "    -H \"X-Vault-Token: \${VAULT_TOKEN}\" \\"
  echo "    -H \"Content-Type: application/json\" \\"
  echo "    -d '{"
  echo "      \"data\": {"
  echo "        \"jaeger-client-secret\": \"${SECRET_jaeger_proxy:-<get-from-above>}\","
  echo "        \"oauth2-proxy-cookie-secret\": \"${COOKIE_SECRET}\""
  echo "      }"
  echo "    }'"
fi
