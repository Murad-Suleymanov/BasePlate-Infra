#!/bin/bash
set -euo pipefail

VAULT_ADDR="${1:?Usage: $0 <vault-addr> <prod|dev> <k8s-api-url>}"
[[ "$VAULT_ADDR" != https://* && "$VAULT_ADDR" != http://* ]] && VAULT_ADDR="https://${VAULT_ADDR}"
export VAULT_ADDR

ENV="${2:?Usage: $0 <vault-addr> <prod|dev> <k8s-api-url>}"
if [[ "$ENV" != "prod" && "$ENV" != "dev" ]]; then
  echo "Error: ENV must be 'prod' or 'dev', got '${ENV}'"
  exit 1
fi

K8S_HOST="${3:?Usage: $0 <vault-addr> <prod|dev> <k8s-api-url>}"

echo "=== Configuring Kubernetes auth for ${ENV} ==="

VSO_SA="vault-secrets-operator-controller-manager"

SA_JWT=$(kubectl get secret vault-auth-token -n vault-secrets-operator-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || \
         kubectl create token "$VSO_SA" -n vault-secrets-operator-system --duration=87600h)

K8S_CA=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

vault write auth/kubernetes-${ENV}/config \
  kubernetes_host="${K8S_HOST}" \
  kubernetes_ca_cert="${K8S_CA}" \
  token_reviewer_jwt="${SA_JWT}"

echo "=== Creating policy for ${ENV} ==="
vault policy write ${ENV}-secrets - <<EOF
path "secret/data/${ENV}/*" {
  capabilities = ["read"]
}
EOF

echo "=== Creating role for ${ENV} VSO ==="
vault write auth/kubernetes-${ENV}/role/vault-secrets-operator \
  bound_service_account_names="$VSO_SA" \
  bound_service_account_namespaces=vault-secrets-operator-system \
  policies=${ENV}-secrets \
  ttl=1h

echo "=== Done. VSO in ${ENV} cluster can now read secret/${ENV}/* ==="
