# BasePlate-Infra

Infrastructure manifests and ArgoCD application definitions for the **Easy-Deploy** platform.

## Repository Layout

```
BasePlate-Infra/
├── argocd/                          # ArgoCD Application / ApplicationSet
│   ├── application-platform.yaml    # CRD + Operator  (→ BasePlate repo)
│   ├── application-infra.yaml       # Gateway, Registry, Webhook (→ this repo)
│   ├── application-gateway.yaml     # NGINX Gateway Fabric (Helm)
│   ├── application-cert-manager.yaml# cert-manager (Helm)
│   ├── application-monitoring.yaml  # kube-prometheus-stack (Helm)
│   ├── application-external-dns.yaml# ExternalDNS (Helm)
│   ├── applicationset-birservices.yaml # Developer services (→ BasePlate-Dev)
│   └── README.md
├── manifests/                       # Kustomize manifests deployed by application-infra
│   ├── gateway/                     # Gateway, TLS, ClusterIssuers, routes
│   ├── registry/                    # In-cluster container registry
│   ├── operator/                    # Webhook Service + HTTPRoute
│   └── kustomization.yaml
├── install-gateway-api-crds.sh      # One-time: install Gateway API CRDs
├── install-kube-prometheus-crds.sh  # One-time: install Prometheus Operator CRDs
├── verify-kube-prometheus-stack.sh  # Verify monitoring stack health
└── README.md
```

## Related Repositories

| Repo | Purpose |
|------|---------|
| [BasePlate](https://github.com/Murad-Suleymanov/BasePlate) | Go operator, CRD, Helm chart, operator deployment manifests |
| **BasePlate-Infra** (this) | ArgoCD apps, infra manifests, install scripts |
| [BasePlate-Dev](https://github.com/Murad-Suleymanov/BasePlate-Dev) | Developer YAML files (`*/*.yaml (service_name/namespace_name.yaml)`) |

## Quick Start

```bash
# 1. Install CRDs (one-time)
bash install-gateway-api-crds.sh
bash install-kube-prometheus-crds.sh

# 2. Apply all ArgoCD applications
kubectl apply -f argocd/ -n argocd
```

ArgoCD will automatically sync and deploy all platform components.

## ArgoCD Static Password

Default password: `EasyDeploy2026`

```bash
# PowerShell
.\scripts\set-argocd-password.ps1

# Bash
./scripts/set-argocd-password.sh
```

Manual: [bcrypt-generator.com](https://bcrypt-generator.com/) → `EasyDeploy2026` yaz → hash copy et → aşağıdakı əmrdə BURAYA əvəz et:

```bash
kubectl -n argocd patch secret argocd-secret --type merge -p '{"stringData":{"admin.password":"BURAYA_HASH","admin.passwordMtime":"2025-03-11T00:00:00Z"}}'
```
