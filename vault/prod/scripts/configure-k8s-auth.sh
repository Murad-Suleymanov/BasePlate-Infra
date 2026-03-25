#!/bin/bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.easysolution.work}"
ENV="${1:?Usage: $0 <prod|dev>}"
K8S_HOST="${2:?Usage: $0 <prod|dev> <k8s-api-url>}"

export VAULT_ADDR

echo "=== Configuring Kubernetes auth for ${ENV} ==="

SA_JWT=$(kubectl get secret vault-auth-token -n vault-secrets-operator-system -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || \
         kubectl create token vault-secrets-operator -n vault-secrets-operator-system --duration=87600h)

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
  bound_service_account_names=vault-secrets-operator \
  bound_service_account_namespaces=vault-secrets-operator-system \
  policies=${ENV}-secrets \
  ttl=1h

echo "=== Done. VSO in ${ENV} cluster can now read secret/${ENV}/* ==="
