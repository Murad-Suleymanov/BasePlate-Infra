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

## 9) Secrets management with Vault

All secrets are managed through HashiCorp Vault and synced to Kubernetes via Vault Secrets Operator (VSO).

### Architecture

A single Vault server (`vault.easysolution.work`) serves both prod and dev clusters.
Secret paths are separated by environment prefix: `secret/prod/*` and `secret/dev/*`.
Each cluster authenticates via its own Kubernetes auth method (`kubernetes-prod` / `kubernetes-dev`).

### 9a) Vault server setup

On the Vault server:

```bash
cd ~/BasePlate-Infra/vault/prod

# Install Vault binary + systemd service
bash scripts/install-vault.sh

# Place TLS certificates
sudo cp /path/to/fullchain.pem /etc/vault.d/tls/
sudo cp /path/to/privkey.pem /etc/vault.d/tls/
sudo chown vault:vault /etc/vault.d/tls/*

# Start Vault
sudo systemctl start vault

# Initialize and configure
export VAULT_ADDR=https://vault.easysolution.work
bash scripts/init-vault.sh
```

**Save the unseal keys and root token securely. They cannot be recovered.**

After init, populate the actual secret values:

```bash
vault kv put secret/prod/monitoring/grafana \
  admin-user=admin \
  admin-password='<GRAFANA_PASSWORD>'

vault kv put secret/prod/cloudflare \
  cloudflare_api_token='<CLOUDFLARE_TOKEN>'

vault kv put secret/prod/github \
  GITHUB_TOKEN='<GITHUB_TOKEN>'

vault kv put secret/prod/registry \
  htpasswd='<HTPASSWD_STRING>'
```

Configure Kubernetes auth for each cluster:

```bash
# For prod cluster (run with kubectl pointing to prod)
bash scripts/configure-k8s-auth.sh prod https://<PROD_K8S_API>:6443

# For dev cluster (run with kubectl pointing to dev)
bash scripts/configure-k8s-auth.sh dev https://<DEV_K8S_API>:6443
```

### 9b) Add dev secrets to Vault

Dev secrets live in the same Vault under `secret/dev/*`:

```bash
vault kv put secret/dev/monitoring/grafana \
  admin-user=admin \
  admin-password='<GRAFANA_PASSWORD>'

vault kv put secret/dev/cloudflare \
  cloudflare_api_token='<CLOUDFLARE_TOKEN>'

vault kv put secret/dev/github \
  GITHUB_TOKEN='<GITHUB_TOKEN>'

vault kv put secret/dev/registry \
  htpasswd='<HTPASSWD_STRING>'
```

The `configure-k8s-auth.sh` script in step 9a already configures auth for both clusters.
### 9c) Verify ESO sync

After Vault is configured and ArgoCD syncs `vault-secrets-operator` + `secrets-config`:

```bash
kubectl get vaultstaticsecrets -A
kubectl get vaultconnection -n vault-secrets-operator-system
kubectl get vaultauth -n vault-secrets-operator-system
```

All VaultStaticSecrets should show `SecretSynced` status. The following Kubernetes Secrets are automatically created/updated:
- `grafana-admin-secret` in `monitoring`
- `cloudflare-api-token` in `cert-manager` and `external-dns`
- `github-pipeline-secret` in `easy-deploy-system`
- `registry-auth` in `registry`
- `argocd-secret` in `argocd` (merged into existing secret — only `admin.password` and `admin.passwordMtime` keys)

## 10) Sync order (mandatory)

```bash
export ENV=dev   # or prod

cd ~/BasePlate-Infra
kubectl apply -f argocd/${ENV}/application-root.yaml

cd ~/BasePlate
kubectl apply -f argocd/${ENV}/application-root.yaml
```

### ArgoCD password (managed by Vault)

ArgoCD admin password is stored as a bcrypt hash in Vault and synced via VSO.  
The `set-argocd-password.sh` script hashes the password and writes it to Vault.

```bash
# Default password (EasyDeploy2026) for dev
cd ~/BasePlate-Infra/scripts
ENV=dev bash set-argocd-password.sh

# Custom password for prod
ENV=prod bash set-argocd-password.sh 'MyStrongPassword123!'
```

After running the script, VSO will sync the hash to `argocd-secret` in the cluster.  
To force immediate sync:

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found
```

To rotate the password later, simply re-run the script with a new password.

### Grafana password (managed by Vault)

Grafana admin credentials are synced from Vault via VSO. No manual secret creation needed.

To rotate the password, update it in Vault:

```bash
# Prod (from Vault server)
vault kv put secret/prod/monitoring/grafana \
  admin-user=admin \
  admin-password='<NEW_PASSWORD>'

# Dev
vault kv put secret/dev/monitoring/grafana \
  admin-user=admin \
  admin-password='<NEW_PASSWORD>'
```

ESO will sync the updated secret automatically (within `refreshInterval`, default 1h).
To force immediate sync:

```bash
kubectl -n monitoring delete secret grafana-admin-secret
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
- `cloudflare-api-token not found` -> create the secret in `cert-manager` namespace too.
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
