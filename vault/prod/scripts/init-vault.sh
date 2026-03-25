#!/bin/bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.easysolution.work}"
export VAULT_ADDR

echo "=== Initializing Vault ==="
vault operator init -key-shares=3 -key-threshold=2 -format=json > /tmp/vault-init.json

echo ""
echo "!!! SAVE THESE KEYS SECURELY - THEY CANNOT BE RECOVERED !!!"
echo ""
cat /tmp/vault-init.json | jq -r '.unseal_keys_b64[]' | while IFS= read -r key; do
  echo "  Unseal Key: $key"
done
echo ""
echo "  Root Token: $(cat /tmp/vault-init.json | jq -r '.root_token')"
echo ""

echo "=== Unsealing Vault ==="
for i in 0 1; do
  KEY=$(cat /tmp/vault-init.json | jq -r ".unseal_keys_b64[$i]")
  vault operator unseal "$KEY"
done

ROOT_TOKEN=$(cat /tmp/vault-init.json | jq -r '.root_token')
export VAULT_TOKEN="$ROOT_TOKEN"

echo "=== Enabling KV v2 secrets engine ==="
vault secrets enable -path=secret kv-v2

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

echo "=== Enabling Kubernetes auth for prod cluster ==="
vault auth enable -path=kubernetes-prod kubernetes

echo "=== Enabling Kubernetes auth for dev cluster ==="
vault auth enable -path=kubernetes-dev kubernetes

echo ""
echo "=== Vault initialized successfully ==="
echo "Next steps:"
echo "  1. Save unseal keys and root token securely"
echo "  2. Delete /tmp/vault-init.json"
echo "  3. Configure Kubernetes auth endpoints (see docs)"
echo "  4. Update secret values with real credentials"
