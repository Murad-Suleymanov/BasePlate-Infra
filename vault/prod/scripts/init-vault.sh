#!/bin/bash
set -euo pipefail

VAULT_ADDR="${1:?Usage: $0 <vault-addr> [vault-token]}"
[[ "$VAULT_ADDR" != https://* && "$VAULT_ADDR" != http://* ]] && VAULT_ADDR="https://${VAULT_ADDR}"
export VAULT_ADDR

HEALTH=$(curl -sk "${VAULT_ADDR}/v1/sys/health" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")

if [ "$HEALTH" = "000" ]; then
  echo "Vault-a qoşulmaq mümkün olmadı: ${VAULT_ADDR}"
  exit 1
fi

# 501 = not initialized, 200/429/473 = initialized
if [ "$HEALTH" = "501" ]; then
  echo "=== Vault initialized deyil, init edilir ==="
  INIT_OUTPUT=$(vault operator init -key-shares=3 -key-threshold=2)

  UNSEAL_KEY_0=$(echo "$INIT_OUTPUT" | grep 'Unseal Key 1:' | awk '{print $NF}')
  UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | grep 'Unseal Key 2:' | awk '{print $NF}')
  UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | grep 'Unseal Key 3:' | awk '{print $NF}')
  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | grep 'Initial Root Token:' | awk '{print $NF}')

  echo ""
  echo "!!! SAVE THESE KEYS SECURELY - THEY CANNOT BE RECOVERED !!!"
  echo ""
  echo "  Unseal Key 1: $UNSEAL_KEY_0"
  echo "  Unseal Key 2: $UNSEAL_KEY_1"
  echo "  Unseal Key 3: $UNSEAL_KEY_2"
  echo "  Root Token:   $ROOT_TOKEN"
  echo ""

  echo "=== Unsealing Vault ==="
  vault operator unseal "$UNSEAL_KEY_0"
  vault operator unseal "$UNSEAL_KEY_1"
else
  echo "=== Vault artıq initialized olub ==="
  ROOT_TOKEN="${2:-${VAULT_TOKEN:?Vault artıq init olub. Token lazımdır: $0 <vault-addr> <vault-token>}}"
fi

export VAULT_TOKEN="$ROOT_TOKEN"

vault secrets enable -path=secret kv-v2 2>/dev/null && echo "=== KV v2 enabled ===" || echo "=== KV v2 artıq mövcuddur ==="

echo "=== Creating secret paths ==="
vault kv put secret/prod/monitoring/grafana \
  admin-user=admin \
  admin-password='CHANGE_ME'

vault kv put secret/prod/cloudflare \
  cloudflare_api_token='CHANGE_ME'

vault kv put secret/prod/github \
  GITHUB_TOKEN='CHANGE_ME' \
  REGISTRY_USERNAME='CHANGE_ME' \
  REGISTRY_PASSWORD='CHANGE_ME'

vault kv put secret/prod/registry \
  htpasswd='CHANGE_ME'

vault kv put secret/prod/argocd \
  admin.password='CHANGE_ME_BCRYPT_HASH' \
  admin.passwordMtime="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

vault kv put secret/dev/monitoring/grafana \
  admin-user=admin \
  admin-password='CHANGE_ME'

vault kv put secret/dev/cloudflare \
  cloudflare_api_token='CHANGE_ME'

vault kv put secret/dev/github \
  GITHUB_TOKEN='CHANGE_ME' \
  REGISTRY_USERNAME='CHANGE_ME' \
  REGISTRY_PASSWORD='CHANGE_ME'

vault kv put secret/dev/registry \
  htpasswd='CHANGE_ME'

vault kv put secret/dev/argocd \
  admin.password='CHANGE_ME_BCRYPT_HASH' \
  admin.passwordMtime="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

vault auth enable -path=kubernetes-prod kubernetes 2>/dev/null && echo "=== kubernetes-prod auth enabled ===" || echo "=== kubernetes-prod auth artıq mövcuddur ==="
vault auth enable -path=kubernetes-dev kubernetes 2>/dev/null && echo "=== kubernetes-dev auth enabled ===" || echo "=== kubernetes-dev auth artıq mövcuddur ==="

echo ""
echo "=== Vault hazırdır ==="
echo "Next steps:"
echo "  1. Unseal keys və root token-i təhlükəsiz saxla"
echo "  2. Kubernetes auth endpoint-ləri konfiqurasiya et (configure-k8s-auth.sh)"
echo "  3. Secret dəyərlərini real credential-larla yenilə"
