# Cluster Runbook (kubeadm, no-surprise flow)

This runbook is based on real issues we encountered, so future cluster setup can be completed without repeated troubleshooting.

Goal: bring any cluster to `Synced + Healthy` in one pass.

## 0) Scope

- OS: Ubuntu 22.04/24.04
- Runtime: containerd
- Kubernetes: kubeadm
- GitOps: ArgoCD
- Repositories:
  - `BasePlate-Infra`
  - `BasePlate` (platform manifests repository)
- Environment selector:
  - `ENV=dev` or `ENV=prod`

## 1) Node preparation (OS + kernel)

```bash
sudo apt update && sudo apt -y upgrade
sudo apt -y install ca-certificates curl gnupg lsb-release apt-transport-https jq git

sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sudo sysctl --system
```

## 2) Install containerd

```bash
sudo apt -y install containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

## 3) Install kubeadm/kubelet/kubectl

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt -y install kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

## 4) kubeadm init + CNI

Automated option (control-plane node: OS → containerd → packages → `kubeadm init` → Calico → local-path + Argo CD + CRD scripts): see `scripts/bootstrap-kubeadm-control-plane.sh` in this repo (`sudo ./scripts/bootstrap-kubeadm-control-plane.sh all`).

```bash
sudo kubeadm init --pod-network-cidr=192.168.0.0/16

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml
kubectl get nodes -o wide
```

Enable Calico Felix metrics (required for Calico ServiceMonitor on port `9091`):

```bash
kubectl -n kube-system set env daemonset/calico-node FELIX_PROMETHEUSMETRICSENABLED=true
kubectl -n kube-system rollout status daemonset/calico-node
```

### 4b) Worker nodes (when you add them later)

1. **Control-plane** (after `init` + CNI): join sətri artıq saxlanılıb — `sudo cat /root/kubeadm-join.sh` (və ya `kubeadm token create --print-join-command` — token müddəti bitərsə).
2. **Hər worker**-də: control-plane ilə **eyni** `K8S_VERSION` (məs. `1.30`), sonra bu repodan:
   - **Minimal (yalnız kubeadm + join):** `scripts/kubeadm-minimal-worker.sh` — `sudo ./scripts/kubeadm-minimal-worker.sh ./join.txt`
   - **Tam bootstrap skripti ilə:** `scripts/bootstrap-kubeadm-worker.sh` (əvvəlki variant).
   ```bash
   cd ~/BasePlate-Infra
   chmod +x scripts/kubeadm-minimal-worker.sh
   # join sətirini faylda saxla (məs. scp ilə /root/kubeadm-join.sh worker-ə kopyala)
   sudo ./scripts/kubeadm-minimal-worker.sh /path/to/join-one-line.txt
   ```
   və ya: `sudo KUBEADM_JOIN_CMD='kubeadm join ...' ./scripts/kubeadm-minimal-worker.sh`
3. Worker-də **`kubeadm init` / Calico / addons işlətmə** — yalnız hazırlıq + `kubeadm join` (`kubeadm-minimal-worker.sh` bunu edir).
4. Yoxlama (control-plane): `kubectl get nodes -o wide`

## 5) Clone repositories

```bash
cd ~
git clone https://github.com/Murad-Suleymanov/BasePlate-Infra.git
git clone https://github.com/Murad-Suleymanov/BasePlate.git
```

## 6) Install ArgoCD (CRD-safe)

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml
kubectl get crd applicationsets.argoproj.io
```

## 7) Install cluster-level dependency CRDs (mandatory)

```bash
cd ~/BasePlate-Infra
bash install-gateway-api-crds.sh
bash install-kube-prometheus-crds.sh

kubectl get crd httproutes.gateway.networking.k8s.io
kubectl get crd applicationsets.argoproj.io
kubectl get crd servicemonitors.monitoring.coreos.com
```

## 8) Install StorageClass (avoid Grafana Pending)

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get sc
```

## 9) Secrets management

All application secrets must exist in the cluster before workloads start.
Two approaches are supported: **Option A** (Vault + VSO, recommended) and **Option B** (manual `kubectl`).

### Secret inventory

| Secret name | Namespace | Keys | Consumer |
|---|---|---|---|
| `grafana-admin-secret` | `monitoring` | `admin-user`, `admin-password` | Grafana (kube-prometheus-stack) |
| `cloudflare-api-token` | `cert-manager` | `cloudflare_api_token` | cert-manager ClusterIssuer |
| `cloudflare-api-token` | `external-dns` | `cloudflare_api_token` | external-dns |
| `github-pipeline-secret` | `easy-deploy-system` | `GITHUB_TOKEN`, `REGISTRY_USERNAME`, `REGISTRY_PASSWORD` | easy-deploy-operator |
| `registry-auth` | `registry` | `htpasswd` | Docker registry |
| `argocd-secret` | `argocd` | `admin.password`, `admin.passwordMtime` | ArgoCD (merge into existing) |

Additionally, `wildcard-tls`, `letsencrypt-account-key`, and `letsencrypt-staging-account-key` are auto-managed by cert-manager and do not require manual creation.

---

### Option A: Vault + VSO (recommended)

A single external Vault server serves both prod and dev clusters.
Secret paths are separated by environment prefix: `secret/prod/*` and `secret/dev/*`.
Each cluster authenticates via its own Kubernetes auth method (`kubernetes-prod` / `kubernetes-dev`).
Vault Secrets Operator (VSO) runs in each cluster and syncs secrets automatically.

#### A1) Vault server setup

On the Vault server:

```bash
cd ~/BasePlate-Infra/vault/prod

# Install Vault binary + systemd service
bash scripts/install-vault.sh

# Place TLS certificates (e.g. from certbot)
sudo mkdir -p /etc/vault.d/tls
sudo cp /path/to/fullchain.pem /etc/vault.d/tls/
sudo cp /path/to/privkey.pem /etc/vault.d/tls/
sudo chown vault:vault /etc/vault.d/tls/*

# Start Vault
sudo systemctl enable --now vault
```

#### A2) Initialize Vault and create secret paths

```bash
# First time (Vault not yet initialized):
bash scripts/init-vault.sh <VAULT_ADDR>

# Already initialized (e.g. via UI):
bash scripts/init-vault.sh <VAULT_ADDR> <ROOT_TOKEN>
```

**Save the unseal keys and root token securely. They cannot be recovered.**

#### A3) Populate real secret values

Replace placeholder values for each environment:

```bash
export VAULT_ADDR=<VAULT_ADDR>
export VAULT_TOKEN=<ROOT_TOKEN>

# Repeat for ENV=prod and ENV=dev
ENV=prod

vault kv put secret/${ENV}/monitoring/grafana \
  admin-user=admin \
  admin-password='<GRAFANA_PASSWORD>'

vault kv put secret/${ENV}/cloudflare \
  cloudflare_api_token='<CLOUDFLARE_TOKEN>'

vault kv put secret/${ENV}/github \
  GITHUB_TOKEN='<GITHUB_TOKEN>' \
  REGISTRY_USERNAME='<REGISTRY_USERNAME>' \
  REGISTRY_PASSWORD='<REGISTRY_PASSWORD>'

vault kv put secret/${ENV}/registry \
  htpasswd='<HTPASSWD_STRING>'
```

ArgoCD password requires a bcrypt hash (use the helper script after ArgoCD is running — see step 10).

#### A4) Configure Kubernetes authentication

Run from a machine with `kubectl` access to the target cluster and `vault` CLI authenticated:

```bash
export VAULT_ADDR=<VAULT_ADDR>
export VAULT_TOKEN=<ROOT_TOKEN>

# For prod cluster (kubectl pointing to prod)
bash scripts/configure-k8s-auth.sh prod https://<PROD_K8S_API>:6443

# For dev cluster (kubectl pointing to dev)
bash scripts/configure-k8s-auth.sh dev https://<DEV_K8S_API>:6443
```

#### A5) Verify VSO sync

After ArgoCD syncs `vault-secrets-operator` + `secrets-config`:

```bash
kubectl get vaultstaticsecrets -A
kubectl get vaultconnection -n vault-secrets-operator-system
kubectl get vaultauth -n vault-secrets-operator-system
```

All VaultStaticSecrets should show `SecretSynced` status.

---

### Option B: Without Vault (manual secrets)

If Vault is not available, disable `vault-secrets-operator` and `secrets-config` in the environment values override for `infra-applications`:

```yaml
vault-secrets-operator:
  enabled: false
secrets-config:
  enabled: false
```

Then create all secrets manually with `kubectl`:

```bash
export ENV=dev  # or prod

# Grafana
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic grafana-admin-secret -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<GRAFANA_PASSWORD>' \
  --dry-run=client -o yaml | kubectl apply -f -

# Cloudflare (needed in two namespaces)
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic cloudflare-api-token -n cert-manager \
  --from-literal=cloudflare_api_token='<CLOUDFLARE_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic cloudflare-api-token -n external-dns \
  --from-literal=cloudflare_api_token='<CLOUDFLARE_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -

# GitHub pipeline
kubectl create namespace easy-deploy-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic github-pipeline-secret -n easy-deploy-system \
  --from-literal=GITHUB_TOKEN='<GITHUB_TOKEN>' \
  --from-literal=REGISTRY_USERNAME='<REGISTRY_USERNAME>' \
  --from-literal=REGISTRY_PASSWORD='<REGISTRY_PASSWORD>' \
  --dry-run=client -o yaml | kubectl apply -f -

# Registry
kubectl create namespace registry --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic registry-auth -n registry \
  --from-literal=htpasswd='<HTPASSWD_STRING>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

> **Note:** With Option B, secret rotation requires manual `kubectl` commands. There is no automatic sync.

---

## 10) Sync order (mandatory)

```bash
export ENV=dev   # or prod

cd ~/BasePlate-Infra
kubectl apply -f argocd/${ENV}/application-root.yaml

cd ~/BasePlate
kubectl apply -f argocd/${ENV}/application-root.yaml
```

### ArgoCD admin password

ArgoCD requires a bcrypt-hashed password. Use the appropriate method depending on your secrets approach.

**With Vault (Option A):**

The `set-argocd-password.sh` script hashes the password and writes it to Vault. VSO syncs the hash to `argocd-secret`.

```bash
cd ~/BasePlate-Infra/scripts

# Provide password, Vault address, and Vault token
ENV=dev  bash set-argocd-password.sh '<PASSWORD>' <VAULT_ADDR> <VAULT_TOKEN>
ENV=prod bash set-argocd-password.sh '<PASSWORD>' <VAULT_ADDR> <VAULT_TOKEN>
```

VSO will sync within `refreshInterval` (default 1h). To force immediate pickup, delete the auto-generated initial secret:

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found
```

**Without Vault (Option B):**

Use the PowerShell script (Windows) or patch the secret directly:

```powershell
cd .\BasePlate-Infra\scripts
.\set-argocd-password.ps1 "<PASSWORD>" "<ENVIRONMENT>"
```

```bash
# Or on Linux with argocd/docker/python available:
HASH=$(argocd account bcrypt --password '<PASSWORD>')
MTIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kubectl -n argocd patch secret argocd-secret --type merge \
  -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$MTIME\"}}"
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found
kubectl -n argocd rollout restart deployment argocd-server
```

### Grafana password rotation

**With Vault:** update the value in Vault; VSO syncs automatically.

```bash
export VAULT_ADDR=<VAULT_ADDR>
export VAULT_TOKEN=<ROOT_TOKEN>

vault kv put secret/${ENV}/monitoring/grafana \
  admin-user=admin \
  admin-password='<NEW_PASSWORD>'
```

**Without Vault:** recreate the secret and restart Grafana.

```bash
kubectl -n monitoring create secret generic grafana-admin-secret \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<NEW_PASSWORD>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring rollout restart deploy/monitoring-grafana
```

## 11) Stabilization checks

```bash
kubectl -n argocd get applications
kubectl get pods -n cert-manager
kubectl get pods -n monitoring
kubectl get pods -n external-dns
kubectl get httproute -A
kubectl get clusterissuer
```

Certificate propagation checks:

```bash
kubectl -n nginx-gateway get certificate
dig TXT _acme-challenge.easysolution.work @1.1.1.1 +short
dig TXT _acme-challenge.easysolution.work @8.8.8.8 +short
```

## 12) Quick fix map

- `no matches for kind "ApplicationSet"` -> apply `applicationset-crd.yaml` with server-side apply.
- `metadata.annotations: Too long` -> use server-side apply for CRDs (not client-side).
- `no matches for kind "HTTPRoute"` -> run `install-gateway-api-crds.sh`.
- `cloudflare-api-token not found` -> check secret exists in both `cert-manager` and `external-dns` namespaces (see section 9).
- Grafana `Pending` + PVC `local-path` -> install `local-path-provisioner`.
- `Error scraping target ... :9091 ... connection refused` (Calico) -> enable Felix metrics:

```bash
kubectl -n kube-system set env daemonset/calico-node FELIX_PROMETHEUSMETRICSENABLED=true
kubectl -n kube-system rollout status daemonset/calico-node
```

- App `Synced` but `Degraded` -> hard refresh + manual sync:

```bash
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd patch application <app> --type merge -p '{"operation":{"sync":{"prune":true}}}'
```

- Restart ArgoCD app controller:

```bash
kubectl -n argocd rollout restart statefulset/argocd-application-controller
```

## 13) Final success criteria

- `kubectl -n argocd get applications` -> core apps are `Synced + Healthy`
- `kubectl -n nginx-gateway get certificate` -> wildcard cert is `Ready=True`
- `kubectl get clusterissuer` -> `letsencrypt` and `letsencrypt-staging` are `True`
- `kubectl -n external-dns get pods` -> `Running`
- `kubectl -n easy-deploy-system get deploy easy-deploy-operator` -> `READY 1/1`

## 14) Developer YAML rules (important)

Model:

- Folder name = service/app name (example: `hello-nodejs`)
- File name (`dev.yaml` / `prod.yaml`) = environment selector
- Namespace = folder name (`hello-nodejs`)  
  (`dev`/`prod` are not used as namespace names)

New YAML format (HPA + resources):

```yaml
repo: https://github.com/example/hello-nodejs
hpa:
  minReplicas: 2
  maxReplicas: 5
resources:
  requests:
    memory: 200Mi
    cpu: 75m
  limits:
    memory: 400Mi
    cpu: 150m
```

Default behavior:

- If `replicas` is set, HPA is not created (`replicas` has priority)
- If `resources.requests` is omitted:
  - `memory=200Mi`
  - `cpu=75m`
- If `resources.limits` is omitted:
  - limits are calculated as `2x` requests
