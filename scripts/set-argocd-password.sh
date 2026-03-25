#!/bin/bash
# ArgoCD admin password — writes bcrypt hash to Vault, VSO syncs to K8s
# Usage: ./set-argocd-password.sh <password> <vault-addr> <vault-token>
#        ENV=prod ./set-argocd-password.sh <password> https://vault.example.com hvs.xxxxx

set -euo pipefail

PASSWORD="${1:?Usage: $0 <password> <vault-addr> <vault-token>}"
VAULT_ADDR="${2:-${VAULT_ADDR:?Vault address required}}"
VAULT_TOKEN="${3:-${VAULT_TOKEN:?Vault token required}}"
ENVIRONMENT="${ENV:-dev}"

export VAULT_ADDR VAULT_TOKEN

if [ "$ENVIRONMENT" = "prod" ]; then
  ARGO_HOST="argocd.easysolution.work"
else
  ARGO_HOST="argocd-${ENVIRONMENT}.easysolution.work"
fi

get_hash() {
  if command -v argocd &> /dev/null; then
    argocd account bcrypt --password "$1"
  elif command -v docker &> /dev/null; then
    docker run --rm argoproj/argocd:latest argocd account bcrypt --password "$1"
  elif command -v python3 &> /dev/null; then
    python3 -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())" "$1" 2>/dev/null
  elif command -v python &> /dev/null; then
    python -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())" "$1" 2>/dev/null
  else
    return 1
  fi
}

HASH=$(get_hash "$PASSWORD")
if [ -z "$HASH" ]; then
  (command -v pip3 &>/dev/null && pip3 install bcrypt -q 2>/dev/null) || (command -v pip &>/dev/null && pip install bcrypt -q 2>/dev/null)
  HASH=$(get_hash "$PASSWORD")
fi
if [ -z "$HASH" ] || [ "${#HASH}" -lt 50 ]; then
  echo "Bcrypt generate edilə bilmədi. argocd, docker və ya python lazımdır."
  exit 1
fi

MTime=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S)

vault kv put "secret/${ENVIRONMENT}/argocd" \
  "admin.password=${HASH}" \
  "admin.passwordMtime=${MTime}"

kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found=true

echo "Password written to Vault (secret/${ENVIRONMENT}/argocd)"
echo "VSO will sync to argocd-secret within refreshInterval"
echo "Login at https://$ARGO_HOST"
