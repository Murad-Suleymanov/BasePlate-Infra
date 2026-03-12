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
│   └── README.md
├── manifests/                       # Kustomize manifests deployed by application-infra
│   ├── argocd/                      # ApplicationSet (service_name/namespace_name.yaml)
│   ├── gateway/                     # Gateway, TLS, ClusterIssuers, routes
│   ├── registry/                    # In-cluster container registry
│   ├── operator/                    # Webhook Service + HTTPRoute
│   └── kustomization.yaml
├── scripts/
│   ├── bootstrap-pipeline-secret.sh # Yeni cluster: github-pipeline-secret (one-time)
│   └── set-argocd-password.sh
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

## Pipeline Injection (GitHub repo → build → deploy)

Developer BasePlate-Dev-da `repo: https://github.com/user/repo` əlavə edəndə operator avtomatik:
- **Pipeline** — `.github/workflows/build-push.yaml` repo-ya yazır
- **Secrets** — `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` GitHub Actions-a əlavə edir

**Prerequisite:** `github-pipeline-secret` (GITHUB_TOKEN) — [docs/pipeline-injection.md](docs/pipeline-injection.md)

```bash
GITHUB_TOKEN=ghp_xxx ./scripts/bootstrap-pipeline-secret.sh
kubectl -n easy-deploy-system rollout restart deployment easy-deploy-operator
```

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
