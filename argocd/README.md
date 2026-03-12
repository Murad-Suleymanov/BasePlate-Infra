## ArgoCD Applications — BasePlate-Infra

Bu repo bütün ArgoCD Application/ApplicationSet resurslarını və klaster infra manifestlərini saxlayır.

### Repo Strukturu

| Repo | Məzmun |
|------|--------|
| **BasePlate** | Go operator, CRD, Helm chart, operator manifests |
| **BasePlate-Infra** | ArgoCD apps, gateway/registry/webhook manifests, install scripts |
| **BasePlate-Dev** | Developer YAML faylları (`*/*.yaml (service_name/namespace_name.yaml)`) |

### ArgoCD Applications

| Fayl | Nə deploy edir |
|------|----------------|
| `application-platform.yaml` | CRD + Operator (BasePlate repo → `manifests/`) |
| `application-infra.yaml` | Gateway, Registry, Webhook manifests (BasePlate-Infra → `manifests/`) |
| `application-gateway.yaml` | NGINX Gateway Fabric (Helm) |
| `application-cert-manager.yaml` | cert-manager (Helm) |
| `application-monitoring.yaml` | kube-prometheus-stack (Helm) |
| `application-external-dns.yaml` | ExternalDNS (Helm) |
| `manifests/argocd/applicationset-birservices.yaml` | Developer servislər (BasePlate-Dev, service/ns.yaml → chart) |

### İlk Quraşdırma

```bash
# 1. CRD-ləri quraşdır (bir dəfəlik)
bash install-gateway-api-crds.sh
bash install-kube-prometheus-crds.sh

# 2. Bütün ArgoCD application-ları apply et
kubectl apply -f argocd/ -n argocd
```
