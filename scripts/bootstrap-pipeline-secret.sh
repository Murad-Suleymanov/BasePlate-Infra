#!/bin/bash
# Creates the github-pipeline-secret used by the operator for pipeline injection —
# run once per new cluster (skip if already done).
# GITHUB_TOKEN: https://github.com/settings/tokens (scope: repo)
#
# Usage:
#   GITHUB_TOKEN=ghp_xxx ./bootstrap-pipeline-secret.sh

set -e

REGISTRY_USERNAME="${REGISTRY_USERNAME:-admin}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-EasyDeploy2026}"
NAMESPACE="${NAMESPACE:-easy-deploy-system}"

if [ -z "$GITHUB_TOKEN" ]; then
  echo "GITHUB_TOKEN is not set. Create one on GitHub:"
  echo "  https://github.com/settings/tokens → Generate new token (classic)"
  echo "  Scope: repo (full control)"
  echo ""
  read -sp "Enter token: " GITHUB_TOKEN
  echo ""
fi

if [ -z "$GITHUB_TOKEN" ]; then
  echo "GITHUB_TOKEN is required."
  exit 1
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic github-pipeline-secret -n "$NAMESPACE" \
  --from-literal=GITHUB_TOKEN="$GITHUB_TOKEN" \
  --from-literal=REGISTRY_USERNAME="$REGISTRY_USERNAME" \
  --from-literal=REGISTRY_PASSWORD="$REGISTRY_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "OK: github-pipeline-secret created/updated."
echo "Restart the operator: kubectl rollout restart deployment easy-deploy-operator -n $NAMESPACE"
