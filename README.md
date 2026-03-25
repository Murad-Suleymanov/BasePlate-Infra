# BasePlate-Infra

Infrastructure manifests and ArgoCD application definitions for the **Easy-Deploy** platform.

## Repository Layout

```
BasePlate-Infra/
├── argocd/                              # Bootstrap
│   ├── prod/application-root.yaml       # root-infra (prod)
│   └── dev/application-root.yaml        # root-infra (dev)
├── charts/                              # Helm charts
│   ├── infra-applications/              # Generates ArgoCD Application resources
│   ├── applicationsets/                 # Generates ApplicationSet resources
│   ├── secrets-config/                  # VaultAuth + VaultStaticSecret per namespace
│   ├── argocd-config/
│   ├── gateway-config/
│   ├── monitoring-config/
│   └── registry/
├── prod/                                # Prod environment values
│   ├── infra-applications-values.yaml
│   ├── vault-secrets-operator/values/
│   ├── secrets-config/values/
│   └── ...
├── dev/                                 # Dev environment values
│   └── (same structure)
├── vault/prod/                          # Vault server configuration
│   ├── config/
│   │   ├── vault.hcl                    # Vault server config
│   │   └── vault.service                # systemd unit file
│   └── scripts/
│       ├── install-vault.sh             # Install Vault binary
│       ├── init-vault.sh                # Initialize Vault + create secret paths
│       └── configure-k8s-auth.sh        # Configure K8s auth + policy + role
└── README.md
```

## Related Repositories

| Repo | Purpose |
|------|---------|
| [BasePlate](https://github.com/Murad-Suleymanov/BasePlate) | Go operator, CRD, Helm chart, platform Application |
| **BasePlate-Infra** (this) | Infra ArgoCD apps, Vault config, install scripts |
| [BasePlate-Dev](https://github.com/Murad-Suleymanov/BasePlate-Dev) | Developer YAML files (`service_name/env.yaml`) |

---

## Installation (From Scratch)

### Prerequisites

- A Kubernetes cluster (kubeadm, k3s, etc.)
- ArgoCD installed on the cluster
- A separate server for Vault (external to K8s)
- `kubectl`, `curl`, `python3` available on the K8s master node
- `jq`, `helm`, `vault` CLI are **not required** — all scripts use `curl` only

### Required Information

Gather these before starting:

| Information | Example | Used in |
|-------------|---------|---------|
| Vault server DNS | `vault.easysolution.work` | All scripts |
| K8s API **public** IP | `116.203.203.121` | `configure-k8s-auth.sh` — Vault connects to this IP |
| Cloudflare API token | `cf_xxx` | cert-manager, external-dns |
| GitHub token | `ghp_xxx` | easy-deploy pipeline injection |
| Registry htpasswd | `admin:$2b$12$...` | Container registry auth |
| Grafana admin password | any | Grafana UI login |

> **IMPORTANT:** The K8s API IP must be reachable from the Vault server.
> `localhost`, `k8s-api`, or private DNS names **will not work**.
> Test from the Vault server: `curl -sk https://<IP>:6443/healthz`
> Open port 6443 in the firewall **only** for the Vault server's IP.

---

### Step 1: Install CRDs (on K8s master, one-time)

```bash
bash install-gateway-api-crds.sh
bash install-kube-prometheus-crds.sh
```

### Step 2: Install Vault Server (on the Vault server)

```bash
# SSH into the Vault server
bash vault/prod/scripts/install-vault.sh
```

### Step 3: Initialize Vault (from Vault server or K8s master)

**First time** (Vault not yet initialized):
```bash
bash vault/prod/scripts/init-vault.sh vault.easysolution.work
```

Output:
```
Unseal Key 1: xxxxx
Unseal Key 2: xxxxx
Unseal Key 3: xxxxx
Root Token:   hvs.xxxxx
```

> **SAVE THE UNSEAL KEYS AND ROOT TOKEN IMMEDIATELY!**
> They cannot be recovered. Losing them means losing access to Vault.

**If Vault is already initialized:**
```bash
bash vault/prod/scripts/init-vault.sh vault.easysolution.work <root-token>
```

This script creates:
- KV v2 secret engine at `secret/`
- Secret paths (`secret/prod/*`, `secret/dev/*`) with `CHANGE_ME` placeholder values
- Kubernetes auth backends (`kubernetes-prod`, `kubernetes-dev`)

### Step 4: Apply ArgoCD Root Application (on K8s master, one-time)

```bash
kubectl apply -f argocd/prod/application-root.yaml
```

This automatically deploys everything:
- ArgoCD config, ApplicationSets
- cert-manager, external-dns, nginx-gateway-fabric
- kube-prometheus-stack, metrics-server, monitoring-config
- registry, gateway-config
- **vault-secrets-operator** (VSO)
- **secrets-config** (VaultAuth + VaultStaticSecret per namespace)

> **Expected:** `external-dns` and `Grafana` will crash-loop at this point — this is normal.
> They cannot start without Vault secrets. They will recover automatically after Step 6.

Verify:
```bash
kubectl get applications -n argocd
kubectl get pods -n vault-secrets-operator-system
```

Wait until the VSO pod shows `Running` status before proceeding.

### Step 5: Configure Vault K8s Auth (on K8s master)

```bash
export VAULT_TOKEN=<root-token>
bash vault/prod/scripts/configure-k8s-auth.sh vault.easysolution.work prod https://<K8S_PUBLIC_IP>:6443
```

This script creates:
- Vault kubernetes auth config (K8s CA cert + reviewer JWT)
- Policy: `prod-secrets` — read-only access to `secret/data/prod/*`
- Role: `vault-secrets-operator` — bound to `default` SA, all namespaces

> **ERROR REFERENCE:**
>
> | Error | Cause | Fix |
> |-------|-------|-----|
> | `permission denied` (403) | Vault cannot reach the K8s API | Provide the correct public IP, check firewall |
> | `connection refused` | Port is closed | Open 6443 on K8s master firewall for the Vault server IP |
> | `certificate verify failed` | CA cert mismatch | Re-run the script (CA will be refreshed) |
>
> Verify the config:
> ```bash
> curl -sk -H "X-Vault-Token: ${VAULT_TOKEN}" \
>   https://vault.easysolution.work/v1/auth/kubernetes-prod/config | python3 -m json.tool
> ```
> Check that `kubernetes_host` shows the correct IP. If wrong, simply re-run the script — it overwrites the existing config.

> **FIREWALL NOTES:**
> - Open port 6443 on K8s master **only** for the Vault server's IP.
> - If you opened it for the wrong IP: `ufw delete allow from <WRONG_IP> to any port 6443`
> - All scripts are idempotent — re-running them with the correct values overwrites previous config.

### Step 6: Update Secret Values

Replace the `CHANGE_ME` placeholders in Vault with real credentials:

```bash
export VAULT_TOKEN=<root-token>
export VAULT_ADDR=https://vault.easysolution.work

# Grafana (pod will NOT start without this secret!)
curl -sk -X POST "${VAULT_ADDR}/v1/secret/data/prod/monitoring/grafana" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -d '{"data": {"admin-user": "admin", "admin-password": "YOUR_PASSWORD"}}'

# Cloudflare (external-dns will NOT start, cert-manager cannot issue certificates!)
curl -sk -X POST "${VAULT_ADDR}/v1/secret/data/prod/cloudflare" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -d '{"data": {"cloudflare_api_token": "YOUR_CF_TOKEN"}}'

# GitHub (pod starts but pipeline injection will not work)
curl -sk -X POST "${VAULT_ADDR}/v1/secret/data/prod/github" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -d '{"data": {"GITHUB_TOKEN": "ghp_xxx", "REGISTRY_USERNAME": "xxx", "REGISTRY_PASSWORD": "xxx"}}'

# Registry
curl -sk -X POST "${VAULT_ADDR}/v1/secret/data/prod/registry" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -d '{"data": {"htpasswd": "admin:BCRYPT_HASH"}}'

# ArgoCD (optional — ArgoCD creates its own secret)
curl -sk -X POST "${VAULT_ADDR}/v1/secret/data/prod/argocd" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -d '{"data": {"admin.password": "BCRYPT_HASH", "admin.passwordMtime": "2026-01-01T00:00:00Z"}}'
```

VSO syncs secrets every 1 hour. To force an immediate sync:

```bash
kubectl get vaultstaticsecrets -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers | \
  while read ns name; do
    kubectl annotate vaultstaticsecret "$name" -n "$ns" \
      secrets.hashicorp.com/force-sync="$(date +%s)" --overwrite
  done
```

### Step 7: Verify

```bash
# All secrets created?
kubectl get secret grafana-admin-secret -n monitoring
kubectl get secret cloudflare-api-token -n cert-manager
kubectl get secret cloudflare-api-token -n external-dns
kubectl get secret github-pipeline-secret -n easy-deploy-system
kubectl get secret registry-auth -n registry

# All pods running?
kubectl get pods -A | grep -v Running

# All ArgoCD apps synced?
kubectl get applications -n argocd
```

---

## Secret Dependency Matrix

| App | Secret | Behavior Without Secret |
|-----|--------|------------------------|
| **external-dns** | `cloudflare-api-token` | Pod **will not start** (env required) |
| **Grafana** | `grafana-admin-secret` | Pod **will not start** (existingSecret not found) |
| **cert-manager ClusterIssuer** | `cloudflare-api-token` | cert-manager starts, but **cannot issue certificates** |
| **easy-deploy-platform** | `github-pipeline-secret` | Pod starts (`optional: true`), but **pipeline injection disabled** |
| **registry** | `registry-auth` | htpasswd is hardcoded in values, **starts fine** |
| **ArgoCD** | `argocd-secret` | ArgoCD creates its own secret, **starts fine** |

---

## Vault to K8s Secret Flow

```
Vault Server (vault.easysolution.work)
  └─ secret/prod/monitoring/grafana
       │
       │  K8s Auth (default SA token login)
       ▼
  VSO Operator (vault-secrets-operator-system)
       │
       │  VaultStaticSecret → reads from Vault
       │  Creates K8s Secret (syncs every 1h)
       ▼
  K8s Secret: grafana-admin-secret (monitoring namespace)
```

### Components

| Component | Namespace | Role |
|-----------|-----------|------|
| Vault Server | external server | Secret storage with versioning |
| VSO | vault-secrets-operator-system | Syncs Vault secrets to K8s Secrets |
| VaultConnection | each target namespace | Vault server address |
| VaultAuth | each target namespace | K8s auth method (uses `default` SA) |
| VaultStaticSecret | each target namespace | Maps Vault path to K8s Secret |

---

## Adding a New Secret

1. Create the secret in Vault:
```bash
curl -sk -X POST "${VAULT_ADDR}/v1/secret/data/prod/my/path" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -d '{"data": {"key": "value"}}'
```

2. Add it to `prod/secrets-config/values/secrets-config-values.yaml`:
```yaml
secrets:
  my-new-secret:
    enabled: true
    name: my-k8s-secret-name
    namespace: my-namespace
    refreshInterval: 1h
    vaultPath: my/path
```

3. Push to git. The template automatically creates VaultConnection + VaultAuth + VaultStaticSecret.

> No additional configuration is needed even for new namespaces — the template and Vault role (`*` wildcard) handle it automatically.

---

## Troubleshooting

### VSO is not creating secrets

```bash
# Check VaultStaticSecret status
kubectl describe vaultstaticsecret <name> -n <namespace>

# Check VSO logs
kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator --tail=20
```

| VSO Error | Cause | Fix |
|-----------|-------|-----|
| `VaultAuth "vault-auth" not found` | secrets-config not synced | Check `kubectl get application secrets-config -n argocd`, push changes to git |
| `ServiceAccount not found` | VSO looks for SA in wrong namespace | VaultAuth must exist in each target namespace (template handles this automatically) |
| `permission denied` (403) | Vault cannot reach K8s API | Re-run `configure-k8s-auth.sh` with correct public IP |
| `connection refused` | Vault server unreachable | Verify Vault is running, check DNS and TLS |

### root-infra is missing

`root-infra` is not managed by any other application. If deleted, it does not come back automatically:
```bash
kubectl apply -f argocd/prod/application-root.yaml
```

### Inspecting Vault Configuration

```bash
export VAULT_TOKEN=<root-token>
export VAULT_ADDR=https://vault.easysolution.work

# K8s auth config (is kubernetes_host the correct IP?)
curl -sk -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/auth/kubernetes-prod/config" | python3 -m json.tool

# Role (is bound_service_account correct?)
curl -sk -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/auth/kubernetes-prod/role/vault-secrets-operator" | python3 -m json.tool

# Policy
curl -sk -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/policies/acl/prod-secrets" | python3 -m json.tool

# Read a secret (test)
curl -sk -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/secret/data/prod/monitoring/grafana" | python3 -m json.tool
```

### Fixing Incorrect Vault Configuration

All scripts are idempotent — re-running them overwrites the existing configuration:
```bash
export VAULT_TOKEN=<root-token>
bash vault/prod/scripts/configure-k8s-auth.sh vault.easysolution.work prod https://<CORRECT_IP>:6443
```

---

## Manual Sync Trigger

```bash
# Single secret
kubectl annotate vaultstaticsecret <name> -n <namespace> \
  secrets.hashicorp.com/force-sync="$(date +%s)" --overwrite

# All secrets
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

When a developer adds `repo: https://github.com/user/repo` in BasePlate-Dev, the operator automatically:
- Injects `.github/workflows/build-push.yaml` into the repo
- Adds `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` to GitHub Actions secrets

**Prerequisite:** `github-pipeline-secret` must contain a valid `GITHUB_TOKEN` — synced from Vault (configured in Step 6).
