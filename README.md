# BasePlate-Infra

Infrastructure manifests and ArgoCD application definitions for the **Easy-Deploy** platform.

## Repository Layout

```
BasePlate-Infra/
├── argocd/                              # Bootstrap
│   ├── prod/application-root.yaml       # root-infra (prod)
│   └── dev/application-root.yaml        # root-infra (dev)
├── charts/                              # Helm charts (local)
│   ├── infra-applications/              # Generates ArgoCD Application resources
│   ├── applicationsets/                 # Generates ApplicationSet resources (developer apps)
│   ├── argocd-config/                   # ArgoCD route, insecure mode, extra resources
│   ├── gateway-config/                  # Gateway, ClusterIssuer, wildcard cert
│   ├── monitoring-config/               # Grafana dashboards, ServiceMonitors, alerts, Grafana route
│   ├── registry/                        # Container registry + UI + GC
│   ├── secrets-config/                  # VaultConnection + VaultAuth + VaultStaticSecret per namespace
│   └── istio-config/                    # PeerAuthentication, Telemetry, OAuth2 Proxy, Kiali/Jaeger routes
├── prod/                                # Prod environment Helm value overrides
│   ├── infra-applications-values.yaml
│   ├── kube-prometheus-stack/values/
│   ├── istio-config/values/
│   ├── kiali/values/
│   ├── secrets-config/values/
│   └── ...                              # (one folder per application)
├── dev/                                 # Dev environment (same structure as prod)
├── server/                              # Bare-metal server install scripts
│   ├── vault/
│   │   ├── install-vault.sh             # Install Vault binary + Nginx reverse proxy
│   │   ├── init-vault.sh                # Initialize Vault + create secret paths
│   │   └── configure-k8s-auth.sh        # Configure K8s auth method + policy + role
│   └── keycloak/
│       ├── install-keycloak.sh          # Install Keycloak + Nginx reverse proxy
│       └── configure-clients.sh         # Create realm, OIDC clients, users; write secrets to Vault
├── scripts/                             # Helper scripts
│   ├── set-argocd-password.sh           # Hash + store ArgoCD admin password
│   ├── set-argocd-password.ps1          # Windows variant
│   └── bootstrap-pipeline-secret.sh     # One-time GitHub token bootstrap
├── docs/                                # Documentation
│   ├── cluster-kubeadm-installation.md  # Full cluster setup from scratch
│   ├── keycloak-oidc-setup.md           # Keycloak + OAuth2 Proxy + Kiali OIDC
│   ├── istio-service-mesh.md            # Istio, Kiali, Jaeger, mTLS, tracing, metrics
│   ├── monitoring-components.md         # Component metric/ServiceMonitor matrix
│   └── pipeline-injection.md            # Operator → GitHub Actions pipeline injection
├── install-gateway-api-crds.sh          # Gateway API CRDs (one-time)
├── install-kube-prometheus-crds.sh      # Prometheus CRDs (one-time)
├── verify-kube-prometheus-stack.sh      # Verify Prometheus stack health
└── README.md
```

## Related Repositories

| Repo | Purpose |
|------|---------|
| [BasePlate](https://github.com/Murad-Suleymanov/BasePlate) | Go operator, CRD, Helm chart, platform Application |
| **BasePlate-Infra** (this) | Infra ArgoCD apps, Helm charts, server scripts, documentation |
| [BasePlate-Dev](https://github.com/Murad-Suleymanov/BasePlate-Dev) | Developer YAML files (`service_name/env.yaml`) |

---

## Documentation Index

| Document | Covers |
|----------|--------|
| **This README** | Architecture overview, installation from scratch, secrets, troubleshooting |
| [Cluster Installation](docs/cluster-kubeadm-installation.md) | Full kubeadm cluster setup (OS → Calico → ArgoCD → secrets → stabilization) |
| [Istio Service Mesh](docs/istio-service-mesh.md) | Istio architecture, mTLS, tracing, Kiali, Jaeger, Envoy metrics |
| [Keycloak OIDC Setup](docs/keycloak-oidc-setup.md) | Keycloak server, realm, clients, OAuth2 Proxy for Jaeger, Kiali OpenID |
| [Monitoring Components](docs/monitoring-components.md) | Per-component metric endpoint / ServiceMonitor / dashboard matrix |
| [Pipeline Injection](docs/pipeline-injection.md) | Operator → GitHub Actions workflow + secrets injection |

---

## Architecture Overview

### GitOps Model

```
Developer pushes YAML to BasePlate-Dev
        │
        ▼
ArgoCD ApplicationSet (watches BasePlate-Dev)
        │
        ▼
Generates per-service Application (chart from BasePlate)
        │
        ▼
Easy-Deploy Operator reconciles BirService CR
        │
        ▼
Deployment + Service + HPA + Istio sidecar
```

### Infrastructure Components

All components are managed by ArgoCD via the `infra-applications` chart. Each component is an ArgoCD Application.

| Component | Chart | Version | Namespace | Purpose |
|-----------|-------|---------|-----------|---------|
| **argocd-config** | local | — | argocd | Route, insecure mode, extra resources |
| **applicationsets** | local | — | argocd | Developer app generation from BasePlate-Dev |
| **easy-deploy-platform** | BasePlate repo | — | easy-deploy-system | Go operator + CRDs |
| **gateway-config** | local | — | nginx-gateway | Gateway, ClusterIssuer (Let's Encrypt), wildcard cert |
| **nginx-gateway-fabric** | ghcr.io/nginx/charts | 2.4.2 | nginx-gateway | Gateway API implementation (ingress) |
| **cert-manager** | jetstack | v1.17.2 | cert-manager | TLS certificate automation |
| **external-dns** | kubernetes-sigs | 1.16.1 | external-dns | Cloudflare DNS record management |
| **kube-prometheus-stack** | prometheus-community | 82.4.3 | monitoring | Prometheus + Grafana + Alertmanager |
| **metrics-server** | kubernetes-sigs | 3.12.2 | kube-system | HPA / `kubectl top` metrics |
| **monitoring-config** | local | — | monitoring | Dashboards, ServiceMonitors, alerts, Grafana route |
| **registry** | local | — | registry | Container registry + UI + GC cron |
| **vault-secrets-operator** | hashicorp | 0.9.0 | vault-secrets-operator-system | Syncs Vault secrets to K8s Secrets |
| **secrets-config** | local | — | (multi-namespace) | VaultConnection + VaultAuth + VaultStaticSecret |
| **istio-base** | istio | 1.29.1 | istio-system | Istio CRDs |
| **istiod** | istio | 1.29.1 | istio-system | Istio control plane |
| **istio-config** | local | — | istio-system | mTLS, Telemetry, OAuth2 Proxy, Kiali/Jaeger routes |
| **kiali-server** | kiali.org | 2.21.0 | istio-system | Service mesh observability dashboard |
| **jaeger** | jaegertracing | 4.6.0 | istio-system | Distributed tracing |

### External Servers (Bare-Metal)

These run **outside** the Kubernetes cluster on a separate server:

| Service | DNS | Install Script | Purpose |
|---------|-----|---------------|---------|
| **Vault** | `vault.easysolution.work` | `server/vault/install-vault.sh` | Secret management (KV v2) |
| **Keycloak** | `keycloak.easysolution.work` | `server/keycloak/install-keycloak.sh` | OIDC Identity Provider |

Both use Nginx reverse proxy with TLS (Let's Encrypt wildcard `*.easysolution.work`).

---

## Installation (From Scratch)

> For detailed OS-level setup (kernel, containerd, kubeadm), see [Cluster Installation](docs/cluster-kubeadm-installation.md).

### Prerequisites

- A Kubernetes cluster (kubeadm recommended, see [cluster doc](docs/cluster-kubeadm-installation.md))
- ArgoCD installed on the cluster
- A separate server for Vault and Keycloak (external to K8s)
- `kubectl`, `curl`, `python3` available on the K8s master node
- TLS certificates for `*.easysolution.work` (Let's Encrypt)

### Required Information

| Information | Example | Used in |
|-------------|---------|---------|
| Vault server DNS | `vault.easysolution.work` | All Vault scripts, secrets-config |
| Keycloak server DNS | `keycloak.easysolution.work` | OIDC clients, Kiali/Jaeger auth |
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

### Step 2: Install Vault Server (on the external server)

```bash
# SSH into the server
cd ~/BasePlate-Infra
bash server/vault/install-vault.sh
```

This installs Vault binary, creates an Nginx reverse proxy for `vault.easysolution.work` with TLS, and starts Vault as a systemd service.

### Step 3: Initialize Vault

**First time** (Vault not yet initialized):
```bash
bash server/vault/init-vault.sh vault.easysolution.work
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
bash server/vault/init-vault.sh vault.easysolution.work <root-token>
```

This script creates:
- KV v2 secret engine at `secret/`
- Secret paths (`secret/prod/*`, `secret/dev/*`) with `CHANGE_ME` placeholder values
- Kubernetes auth backends (`kubernetes-prod`, `kubernetes-dev`)

### Step 4: Install Keycloak (on the external server)

```bash
bash server/keycloak/install-keycloak.sh
```

This installs Keycloak, creates an Nginx reverse proxy for `keycloak.easysolution.work` with TLS. After installation, configure OIDC clients:

```bash
bash server/keycloak/configure-clients.sh
```

This creates the `istio` realm, `jaeger-proxy` (confidential) and `kiali` (public) clients, and a `viewer` user. See [Keycloak OIDC Setup](docs/keycloak-oidc-setup.md) for detailed configuration.

### Step 5: Apply ArgoCD Root Application (on K8s master, one-time)

```bash
kubectl apply -f argocd/prod/application-root.yaml
```

This automatically deploys everything:
- ArgoCD config, ApplicationSets
- cert-manager, external-dns, nginx-gateway-fabric
- kube-prometheus-stack, metrics-server, monitoring-config
- registry, gateway-config
- **vault-secrets-operator** (VSO) + **secrets-config**
- **Istio** (base + istiod + istio-config)
- **Kiali** + **Jaeger**

> **Expected:** `external-dns` and `Grafana` will crash-loop at this point — this is normal.
> They cannot start without Vault secrets. They will recover automatically after Step 7.

Verify:
```bash
kubectl get applications -n argocd
kubectl get pods -n vault-secrets-operator-system
```

Wait until the VSO pod shows `Running` status before proceeding.

### Step 6: Configure Vault K8s Auth (on K8s master)

```bash
export VAULT_TOKEN=<root-token>
bash server/vault/configure-k8s-auth.sh vault.easysolution.work prod https://<K8S_PUBLIC_IP>:6443
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

### Step 7: Update Secret Values

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

# Keycloak secrets (for Jaeger OAuth2 Proxy)
curl -sk -X POST "${VAULT_ADDR}/v1/secret/data/istio/keycloak" \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -d '{"data": {"jaeger-client-secret": "CLIENT_SECRET_FROM_KEYCLOAK", "oauth2-proxy-cookie-secret": "RANDOM_32BYTE_BASE64"}}'
```

Generate a cookie secret:
```bash
python3 -c "import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())"
```

VSO syncs secrets every 1 hour. To force an immediate sync:

```bash
kubectl get vaultstaticsecrets -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' --no-headers | \
  while read ns name; do
    kubectl annotate vaultstaticsecret "$name" -n "$ns" \
      secrets.hashicorp.com/force-sync="$(date +%s)" --overwrite
  done
```

### Step 8: Verify

```bash
# All secrets created?
kubectl get secret grafana-admin-secret -n monitoring
kubectl get secret cloudflare-api-token -n cert-manager
kubectl get secret cloudflare-api-token -n external-dns
kubectl get secret github-pipeline-secret -n easy-deploy-system
kubectl get secret registry-auth -n registry
kubectl get secret keycloak-secrets -n istio-system

# All pods running?
kubectl get pods -A | grep -v Running

# All ArgoCD apps synced?
kubectl get applications -n argocd
```

---

## Secret Dependency Matrix

| App | Secret | Vault Path | Behavior Without Secret |
|-----|--------|------------|------------------------|
| **external-dns** | `cloudflare-api-token` | `{env}/cloudflare` | Pod **will not start** (env required) |
| **Grafana** | `grafana-admin-secret` | `{env}/monitoring/grafana` | Pod **will not start** (existingSecret not found) |
| **cert-manager ClusterIssuer** | `cloudflare-api-token` | `{env}/cloudflare` | cert-manager starts, but **cannot issue certificates** |
| **easy-deploy-platform** | `github-pipeline-secret` | `{env}/github` | Pod starts (`optional: true`), but **pipeline injection disabled** |
| **registry** | `registry-auth` | `{env}/registry` | htpasswd is hardcoded in values, **starts fine** |
| **ArgoCD** | `argocd-secret` | `{env}/argocd` | ArgoCD creates its own secret, **starts fine** |
| **OAuth2 Proxy (Jaeger)** | `keycloak-secrets` | `istio/keycloak` | OAuth2 Proxy **will not start** (env required) |

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

## Environment Differences

| Setting | Prod | Dev |
|---------|------|-----|
| Target IP | `116.203.203.121` | `178.104.84.100` |
| Domain pattern | `*.easysolution.work` | `*-dev.easysolution.work` |
| Prometheus retention | 7d | 3d |
| Prometheus storage | 10Gi | 5Gi |
| Grafana storage | 2Gi | 1Gi |
| Alertmanager storage | 5Gi | 2Gi |
| Kiali resources (request/limit) | 100m-500m CPU, 256-512Mi | 50m-200m CPU, 128-256Mi |
| Keycloak issuer | `keycloak.easysolution.work` | `keycloak-dev.easysolution.work` |
| Tracing sample rate | 10% | 10% |

Both environments use the same chart templates; only values differ.

---

## Monitoring & Metrics

Prometheus (kube-prometheus-stack) is configured to discover **all** `ServiceMonitor` and `PodMonitor` resources across all namespaces (`selectorNilUsesHelmValues: false`).

The `monitoring-config` chart deploys the following scrape targets:

| Target | Type | Port | Namespace |
|--------|------|------|-----------|
| Easy-Deploy Operator | PodMonitor | :8080/metrics | easy-deploy-system |
| Calico Felix | ServiceMonitor + headless Service | :9091/metrics | kube-system |
| Istiod | ServiceMonitor | :15014/metrics | istio-system |
| Envoy sidecars | PodMonitor | :15090/stats/prometheus | all injected namespaces |
| Kiali | ServiceMonitor | :20001/metrics | istio-system |
| Jaeger | ServiceMonitor | :14269/metrics | istio-system |

See [Monitoring Components](docs/monitoring-components.md) for the full matrix of all components.

Kiali connects to Prometheus at `http://monitoring-kube-prometheus-prometheus.monitoring:9090` and uses Istio metrics (`istio_requests_total`, etc.) to display traffic graphs, error rates, and latency. See [Istio Service Mesh](docs/istio-service-mesh.md) for details.

---

## Troubleshooting

### VSO is not creating secrets

```bash
kubectl describe vaultstaticsecret <name> -n <namespace>
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

# K8s auth config
curl -sk -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/auth/kubernetes-prod/config" | python3 -m json.tool

# Role
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
bash server/vault/configure-k8s-auth.sh vault.easysolution.work prod https://<CORRECT_IP>:6443
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

**Prerequisite:** `github-pipeline-secret` must contain a valid `GITHUB_TOKEN` — synced from Vault (configured in Step 7).

See [Pipeline Injection](docs/pipeline-injection.md) for details.
