## ArgoCD — BasePlate-Infra

**argocd/** yalnız ArgoCD-ə aid məsələləri saxlayır. Bütün Application tərifləri domain qovluqlarında: `manifests/gateway/`, `manifests/monitoring/` və s.

### argocd/ məzmunu

| Fayl | Məqsəd |
|------|--------|
| `application-root.yaml` | root-infra — manifests/ + argocd/ (özünü izləyir) |
| `README.md` | Bu fayl |

### Application tərifləri (manifests/ altında)

| Qovluq | Application faylları |
|--------|----------------------|
| `manifests/gateway/` | gateway-application.yaml, nginx-gateway-fabric-application.yaml |
| `manifests/monitoring/` | monitoring-application.yaml, kube-prometheus-stack-application.yaml, metrics-server-application.yaml |
| `manifests/cert-manager/` | cert-manager-application.yaml |
| `manifests/dns/` | external-dns-application.yaml |
| `manifests/registry/` | registry-application.yaml |
| `manifests/argocd/` | argocd-config-application.yaml |

Platform **BasePlate** repo-da öz root-una malikdir: `BasePlate/argocd/`

### İlk Quraşdırma

```bash
# 1. CRD-ləri quraşdır (bir dəfəlik)
bash install-gateway-api-crds.sh
bash install-kube-prometheus-crds.sh

# 2. Infra root apply et
kubectl apply -f argocd/application-root.yaml

# 3. Platform root apply et (BasePlate repo-dan)
cd ../BasePlate
kubectl apply -f argocd/application-root.yaml
```

**root-infra** (BasePlate-Infra) — gateway, monitoring, cert-manager, dns, registry, argocd-config  
**root-platform** (BasePlate) — easy-deploy-platform
