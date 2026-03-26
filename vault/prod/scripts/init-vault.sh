#!/bin/bash
set -euo pipefail

VAULT_ADDR="${1:?Usage: $0 <vault-addr> [vault-token]}"
[[ "$VAULT_ADDR" != https://* && "$VAULT_ADDR" != http://* ]] && VAULT_ADDR="https://${VAULT_ADDR}"

HEALTH=$(curl -sk "${VAULT_ADDR}/v1/sys/health" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")

if [ "$HEALTH" = "000" ]; then
  echo "Vault-a qoşulmaq mümkün olmadı: ${VAULT_ADDR}"
  exit 1
fi

vault_api() {
  local method="$1" path="$2" data="${3:-}"
  local http_code
  http_code=$(curl -sk -X "$method" \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    ${data:+-d "$data"} \
    -o /tmp/vault_response.json -w "%{http_code}" \
    "${VAULT_ADDR}/v1/${path}")
  if [[ "$http_code" -ge 400 ]]; then
    echo "ERROR (HTTP ${http_code}): $(cat /tmp/vault_response.json)"
    return 1
  fi
}

kv_put() {
  local path="$1" data="$2"
  vault_api POST "secret/data/${path}" "{\"data\": ${data}}"
}

# 501 = not initialized, 200/429/473 = initialized
if [ "$HEALTH" = "501" ]; then
  echo "=== Vault initialized deyil, init edilir ==="
  INIT_RESPONSE=$(curl -sk -X PUT "${VAULT_ADDR}/v1/sys/init" \
    -H "Content-Type: application/json" \
    -d '{"secret_shares": 3, "secret_threshold": 2}')

  UNSEAL_KEY_0=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['keys_base64'][0])")
  UNSEAL_KEY_1=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['keys_base64'][1])")
  UNSEAL_KEY_2=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['keys_base64'][2])")
  ROOT_TOKEN=$(echo "$INIT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

  echo ""
  echo "!!! SAVE THESE KEYS SECURELY - THEY CANNOT BE RECOVERED !!!"
  echo ""
  echo "  Unseal Key 1: $UNSEAL_KEY_0"
  echo "  Unseal Key 2: $UNSEAL_KEY_1"
  echo "  Unseal Key 3: $UNSEAL_KEY_2"
  echo "  Root Token:   $ROOT_TOKEN"
  echo ""

  echo "=== Unsealing Vault ==="
  curl -sk -X PUT "${VAULT_ADDR}/v1/sys/unseal" -d "{\"key\": \"${UNSEAL_KEY_0}\"}" > /dev/null
  curl -sk -X PUT "${VAULT_ADDR}/v1/sys/unseal" -d "{\"key\": \"${UNSEAL_KEY_1}\"}" > /dev/null
  echo "Vault unsealed."
else
  echo "=== Vault artıq initialized olub ==="
  ROOT_TOKEN="${2:-${VAULT_TOKEN:?Vault artıq init olub. Token lazımdır: $0 <vault-addr> <vault-token>}}"
fi

export VAULT_TOKEN="$ROOT_TOKEN"

echo "=== Enabling KV v2 ==="
vault_api POST "sys/mounts/secret" '{"type": "kv", "options": {"version": "2"}}' && echo "KV v2 enabled" || echo "KV v2 artıq mövcuddur"

echo "=== Creating secret paths ==="

kv_put "prod/monitoring/grafana" '{"admin-user": "admin", "admin-password": "CHANGE_ME"}'
kv_put "prod/cloudflare"         '{"cloudflare_api_token": "CHANGE_ME"}'
kv_put "prod/github"             '{"GITHUB_TOKEN": "CHANGE_ME", "REGISTRY_USERNAME": "CHANGE_ME", "REGISTRY_PASSWORD": "CHANGE_ME"}'
kv_put "prod/registry"           '{"htpasswd": "CHANGE_ME"}'
kv_put "prod/argocd"             "{\"admin.password\": \"CHANGE_ME_BCRYPT_HASH\", \"admin.passwordMtime\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

kv_put "istio/keycloak"          '{"jaeger-client-secret": "CHANGE_ME", "oauth2-proxy-cookie-secret": "CHANGE_ME"}'

kv_put "dev/monitoring/grafana"  '{"admin-user": "admin", "admin-password": "CHANGE_ME"}'
kv_put "dev/cloudflare"          '{"cloudflare_api_token": "CHANGE_ME"}'
kv_put "dev/github"              '{"GITHUB_TOKEN": "CHANGE_ME", "REGISTRY_USERNAME": "CHANGE_ME", "REGISTRY_PASSWORD": "CHANGE_ME"}'
kv_put "dev/registry"            '{"htpasswd": "CHANGE_ME"}'
kv_put "dev/argocd"              "{\"admin.password\": \"CHANGE_ME_BCRYPT_HASH\", \"admin.passwordMtime\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

echo "=== Enabling Kubernetes auth ==="
vault_api POST "sys/auth/kubernetes-prod" '{"type": "kubernetes"}' && echo "kubernetes-prod auth enabled" || echo "kubernetes-prod auth artıq mövcuddur"
vault_api POST "sys/auth/kubernetes-dev"  '{"type": "kubernetes"}' && echo "kubernetes-dev auth enabled"  || echo "kubernetes-dev auth artıq mövcuddur"

echo ""
echo "=== Vault hazırdır ==="
echo "Next steps:"
echo "  1. Unseal keys və root token-i təhlükəsiz saxla"
echo "  2. Kubernetes auth endpoint-ləri konfiqurasiya et (configure-k8s-auth.sh)"
echo "  3. Secret dəyərlərini real credential-larla yenilə"
