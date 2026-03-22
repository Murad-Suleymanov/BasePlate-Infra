## ArgoCD — BasePlate-Infra

**argocd/** yalnız ArgoCD-ə aid məsələləri saxlayır. Bütün Application tərifləri domain qovluqlarında: `manifests/gateway/`, `manifests/monitoring/` və s.

### argocd/ məzmunu

| Fayl | Məqsəd |
|------|--------|
| `application-root.yaml` | root-infra — BasePlate-Infra manifests/ + argocd/ (özünü izləyir) |
| `application-root-platform.yaml` | root-platform — BasePlate repo-dan platform manifests/ izləyir |
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

### İlk Quraşdırma

```bash
# 1. CRD-ləri quraşdır (bir dəfəlik)
bash install-gateway-api-crds.sh
bash install-kube-prometheus-crds.sh

# 2. Infra root apply et (hər iki root-u yaradır)
kubectl apply -f argocd/application-root.yaml
```

**root-infra** — gateway, monitoring, cert-manager, dns, registry, argocd-config  
**root-platform** — easy-deploy-platform (BasePlate repo-dan izləyir)
