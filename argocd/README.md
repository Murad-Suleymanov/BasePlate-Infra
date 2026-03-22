## ArgoCD — BasePlate-Infra

**argocd/** yalnız ArgoCD-ə aid məsələləri saxlayır. Bütün Application tərifləri domain qovluqlarında saxlanılır.

### argocd/ məzmunu

| Fayl | Məqsəd |
|------|--------|
| `application-root.yaml` | root-infra — bütün `*-application.yaml` + argocd/ (özünü izləyir) |
| `README.md` | Bu fayl |

### Application tərifləri

| Qovluq | Application faylları |
|--------|----------------------|
| `{env}/gateway/apps/` | gateway-application.yaml, nginx-gateway-fabric-application.yaml |
| `{env}/monitoring/apps/` | monitoring-application.yaml, kube-prometheus-stack-application.yaml, metrics-server-application.yaml |
| `{env}/cert-manager/apps/` | cert-manager-application.yaml |
| `{env}/dns/apps/` | external-dns-application.yaml |
| `{env}/registry/apps/` | registry-application.yaml |
| `{env}/argocd/apps/` | argocd-config-application.yaml, argocd-applicationsets-application.yaml |
| `{env}/platform/apps/` | easy-deploy-platform-application.yaml |

### İlk Quraşdırma

```bash
# 1. CRD-ləri quraşdır (bir dəfəlik)
bash install-gateway-api-crds.sh
bash install-kube-prometheus-crds.sh

# 2. Root apply et
kubectl apply -f argocd/application-root.yaml
```

**root-infra** tək root — gateway, monitoring, cert-manager, dns, registry, argocd-config, platform (hamısı)
