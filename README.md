# BasePlate-Infra

Infrastructure manifests and ArgoCD application definitions for the **Easy-Deploy** platform.

## Repository Layout

```
BasePlate-Infra/
├── argocd/                              # Bootstrap
│   ├── prod/application-root.yaml       # root-infra (prod)
│   └── dev/application-root.yaml        # root-infra (dev)
├── charts/                              # Helm charts
│   ├── infra-applications/              # Application-ları yaradan chart
│   ├── applicationsets/                 # ApplicationSet-ləri yaradan chart
│   ├── secrets-config/                  # VaultAuth + VaultStaticSecret
│   ├── argocd-config/
│   ├── gateway-config/
│   ├── monitoring-config/
│   └── registry/
├── prod/                                # Prod mühit values
│   ├── infra-applications-values.yaml
│   ├── vault-secrets-operator/values/
│   ├── secrets-config/values/
│   └── ...
├── dev/                                 # Dev mühit values
│   └── (eyni struktur)
├── vault/prod/                          # Vault server konfiqurasiyası
│   ├── config/
│   │   ├── vault.hcl                    # Vault server config
│   │   └── vault.service                # systemd service
│   └── scripts/
│       ├── install-vault.sh             # Vault binary quraşdırma
│       ├── init-vault.sh                # Vault init + secret path-lər
│       └── configure-k8s-auth.sh        # K8s auth + policy + role
└── README.md
```

## Related Repositories

| Repo | Purpose |
|------|---------|
| [BasePlate](https://github.com/Murad-Suleymanov/BasePlate) | Go operator, CRD, Helm chart, platform Application |
| **BasePlate-Infra** (this) | Infra ArgoCD apps, Vault config, install scripts |
| [BasePlate-Dev](https://github.com/Murad-Suleymanov/BasePlate-Dev) | Developer YAML files (`service_name/env.yaml`) |

## Quick Start

### 1. Vault Server Quraşdırma (ayrıca serverdə)

```bash
# Vault binary quraşdır
bash vault/prod/scripts/install-vault.sh

# Vault init et (ilk dəfə) — unseal keys və root token çıxacaq
bash vault/prod/scripts/init-vault.sh vault.easysolution.work

# Artıq init olubsa, token ilə:
bash vault/prod/scripts/init-vault.sh vault.easysolution.work <root-token>
```

### 2. CRD-ləri Quraşdır (bir dəfəlik, K8s klasterdə)

```bash
bash install-gateway-api-crds.sh
bash install-kube-prometheus-crds.sh
```

### 3. ArgoCD Root Application (bir dəfəlik)

```bash
kubectl apply -f argocd/prod/application-root.yaml
```

Bu avtomatik deploy edəcək: ArgoCD config, cert-manager, external-dns, nginx-gateway,
kube-prometheus-stack, metrics-server, registry, vault-secrets-operator, secrets-config və s.

### 4. Vault K8s Auth Konfiqurasiyası

VSO pod-u Running olduqdan sonra:

```bash
export VAULT_TOKEN=<root-token>
bash vault/prod/scripts/configure-k8s-auth.sh vault.easysolution.work prod https://<K8S_PUBLIC_IP>:6443
```

**Vacib:** `<K8S_PUBLIC_IP>` — K8s API serverinin Vault serverindən əlçatan olan ünvanı olmalıdır.

### 5. Secret Dəyərlərini Yenilə

Vault-dakı `CHANGE_ME` dəyərlərini real credential-larla əvəz edin:

```bash
export VAULT_TOKEN=<root-token>
export VAULT_ADDR=https://vault.easysolution.work

curl -sk -X POST "${VAULT_ADDR}/v1/secret/data/prod/monitoring/grafana" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -d '{"data": {"admin-user": "admin", "admin-password": "REAL_PASSWORD"}}'

# Digər secret-lər üçün eyni pattern:
# secret/data/prod/cloudflare     → cloudflare_api_token
# secret/data/prod/github         → GITHUB_TOKEN, REGISTRY_USERNAME, REGISTRY_PASSWORD
# secret/data/prod/registry       → htpasswd
# secret/data/prod/argocd         → admin.password (bcrypt hash)
```

## Vault → K8s Secret Axını

```
Vault Server (vault.easysolution.work)
  └─ secret/prod/monitoring/grafana
       │
       │  K8s Auth (default SA token ilə login)
       ▼
  VSO Operator (vault-secrets-operator-system)
       │
       │  VaultStaticSecret → Vault-dan oxuyur
       │  K8s Secret yaradır (hər 1 saatdan sync)
       ▼
  K8s Secret: grafana-admin-secret (monitoring namespace)
```

### Komponentlər

| Komponent | Namespace | Rolu |
|-----------|-----------|------|
| Vault Server | xarici server | Secret saxlama, versioning |
| VSO (vault-secrets-operator) | vault-secrets-operator-system | Vault-dan K8s Secret-ə sync |
| VaultConnection | hər target namespace | Vault server ünvanı |
| VaultAuth | hər target namespace | K8s auth metodu (default SA) |
| VaultStaticSecret | hər target namespace | Hansı Vault path → hansı K8s Secret |

### Yeni Secret Əlavə Etmə

`prod/secrets-config/values/secrets-config-values.yaml`-a əlavə edin:

```yaml
secrets:
  my-new-secret:
    enabled: true
    name: my-k8s-secret-name
    namespace: my-namespace
    refreshInterval: 1h
    vaultPath: my/vault/path
```

Sonra Vault-da secret yaradın və push edin. Template avtomatik VaultConnection + VaultAuth + VaultStaticSecret yaradacaq.

### Manual Sync Trigger

```bash
# Tək secret üçün
kubectl annotate vaultstaticsecret <name> -n <namespace> \
  secrets.hashicorp.com/force-sync="$(date +%s)" --overwrite

# Hamısı üçün
kubectl get vaultstaticsecrets -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers | \
  while read ns name; do
    kubectl annotate vaultstaticsecret "$name" -n "$ns" \
      secrets.hashicorp.com/force-sync="$(date +%s)" --overwrite
  done
```

## ArgoCD

Default password: `EasyDeploy2026`

```bash
./scripts/set-argocd-password.sh
```

## Pipeline Injection

Developer BasePlate-Dev-da `repo: https://github.com/user/repo` əlavə edəndə operator avtomatik:
- `.github/workflows/build-push.yaml` repo-ya yazır
- `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` GitHub Actions-a əlavə edir

**Prerequisite:** `github-pipeline-secret` (GITHUB_TOKEN) — Vault-dan sync olunur.
