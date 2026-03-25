## ArgoCD — BasePlate-Infra

The `argocd/` directory contains bootstrap application manifests. Each environment has its own `application-root.yaml`.

### Files

| File | Purpose |
|------|---------|
| `prod/application-root.yaml` | root-infra (prod) — creates all infra Applications |
| `dev/application-root.yaml` | root-infra (dev) — creates all infra Applications |

### Architecture

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

### Initial Setup

`root-infra` is the only manually created Application. It creates all others:

```bash
kubectl apply -f argocd/prod/application-root.yaml
```

**Note:** `root-infra` is not managed by any other Application. If deleted, it will not be recreated automatically — you must re-apply it with `kubectl apply`.
