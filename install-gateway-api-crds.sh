#!/usr/bin/env bash
set -euo pipefail

# Installs the upstream Kubernetes Gateway API CRDs (standard channel).
#
# Required by Istio's Gateway API support: the `main-gateway` Gateway runs on
# gatewayClassName: istio, and istiod only enables the Gateway API controller
# when these CRDs are present. Run this once before istiod / gateway-config
# are deployed. The CRDs are cluster-scoped and not owned by any Helm release,
# so they survive chart upgrades.

GATEWAY_API_VERSION="v1.2.1"

echo "Installing Gateway API CRDs (standard channel) ${GATEWAY_API_VERSION}..."
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo
echo "Verifying Gateway API CRDs..."
kubectl get crd gatewayclasses.gateway.networking.k8s.io
kubectl get crd gateways.gateway.networking.k8s.io
kubectl get crd httproutes.gateway.networking.k8s.io
kubectl get crd referencegrants.gateway.networking.k8s.io

echo
echo "OK: Gateway API CRDs installed."
