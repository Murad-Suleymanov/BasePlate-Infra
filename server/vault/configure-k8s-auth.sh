#!/bin/bash
set -euo pipefail

# Usage: bash configure-k8s-auth.sh <vault-addr> <prod|dev> <k8s-api-url>
# Run on the K8s master node (needs kubectl access).

VAULT_ADDR="${1:?Usage: $0 <vault-addr> <prod|dev> <k8s-api-url>}"
[[ "$VAULT_ADDR" != https://* && "$VAULT_ADDR" != http://* ]] && VAULT_ADDR="https://${VAULT_ADDR}"

ENV="${2:?Usage: $0 <vault-addr> <prod|dev> <k8s-api-url>}"
if [[ "$ENV" != "prod" && "$ENV" != "dev" ]]; then
  echo "Error: ENV must be 'prod' or 'dev', got '${ENV}'"
  exit 1
fi

K8S_HOST="${3:?Usage: $0 <vault-addr> <prod|dev> <k8s-api-url>}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN mütləq export olunmalıdır}"

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
  echo "OK (HTTP ${http_code})"
}

echo "=== Configuring Kubernetes auth for ${ENV} ==="

echo "--- Reading vault-auth-token from K8s..."
SA_JWT=$(kubectl get secret vault-auth-token -n vault-secrets-operator-system \
  -o jsonpath='{.data.token}' | base64 -d)

if [ -z "$SA_JWT" ]; then
  echo "ERROR: vault-auth-token secret tapılmadı və ya boşdur."
  echo "       ArgoCD secrets-config chart-ı sync etməlidir (vault-auth-token.yaml)."
  exit 1
fi

K8S_CA=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

echo "--- Writing kubernetes auth config..."
vault_api POST "auth/kubernetes-${ENV}/config" "$(cat <<EOJSON
{
  "kubernetes_host": "${K8S_HOST}",
  "kubernetes_ca_cert": $(echo "$K8S_CA" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
  "token_reviewer_jwt": "${SA_JWT}"
}
EOJSON
)"

echo "=== Creating policy for ${ENV} ==="
vault_api PUT "sys/policies/acl/${ENV}-secrets" "$(cat <<EOJSON
{
  "policy": "path \"secret/data/${ENV}/*\" {\n  capabilities = [\"read\"]\n}\npath \"secret/data/istio/*\" {\n  capabilities = [\"read\"]\n}"
}
EOJSON
)"

echo "=== Creating role for ${ENV} VSO ==="
vault_api POST "auth/kubernetes-${ENV}/role/vault-secrets-operator" "$(cat <<EOJSON
{
  "bound_service_account_names": ["default"],
  "bound_service_account_namespaces": ["*"],
  "policies": ["${ENV}-secrets"],
  "ttl": "1h"
}
EOJSON
)"

echo ""
echo "=== Done ==="
echo "VSO ${ENV} cluster-dən secret/${ENV}/* və secret/istio/* oxuya bilər."
echo "Token: long-lived (vault-auth-token Secret, expire olmur)"
