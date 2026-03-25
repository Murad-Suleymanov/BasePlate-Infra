## ArgoCD — BasePlate-Infra

**argocd/** bootstrap application-ları saxlayır. Hər mühit üçün ayrıca `application-root.yaml` var.

### Fayllar

| Fayl | Məqsəd |
|------|--------|
| `prod/application-root.yaml` | root-infra (prod) — bütün infra Application-ları yaradır |
| `dev/application-root.yaml` | root-infra (dev) — bütün infra Application-ları yaradır |

### Arxitektura

```
application-root.yaml
  └─ charts/infra-applications (Helm)
       └─ {env}/infra-applications-values.yaml
            ├─ argocd-config
            ├─ argocd-applicationsets
            ├─ easy-deploy-platform
            ├─ cert-manager
            ├─ external-dns
            ├─ nginx-gateway-fabric
            ├─ kube-prometheus-stack
            ├─ metrics-server
            ├─ gateway-config
            ├─ monitoring-config
            ├─ registry
            ├─ vault-secrets-operator
            └─ secrets-config
```

### İlk Quraşdırma

`root-infra` yeganə əl ilə yaradılan Application-dır. Qalanların hamısını o yaradır:

```bash
kubectl apply -f argocd/prod/application-root.yaml
```

**Qeyd:** `root-infra` heç bir başqa Application tərəfindən idarə olunmur. Silinərsə avtomatik geri gəlmir — yenidən `kubectl apply` lazımdır.
