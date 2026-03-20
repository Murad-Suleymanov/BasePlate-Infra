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

## 9) Create namespaces and secrets (before sync)

```bash
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace easy-deploy-system --dry-run=client -o yaml | kubectl apply -f -
```

Create Cloudflare token in both namespaces:

```bash
kubectl -n external-dns create secret generic cloudflare-api-token \
  --from-literal=cloudflare_api_token='<CLOUDFLARE_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=cloudflare_api_token='<CLOUDFLARE_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Create pipeline secret:

```bash
cd ~/BasePlate-Infra/scripts
GITHUB_TOKEN=<GITHUB_TOKEN> ./bootstrap-pipeline-secret.sh
```

## 10) Sync order (mandatory)

```bash
export ENV=dev   # or prod

cd ~/BasePlate-Infra
kubectl apply -f argocd/${ENV}/application-root.yaml

cd ~/BasePlate
kubectl apply -f argocd/${ENV}/application-root.yaml
```

### ArgoCD password bootstrap (mandatory)

After ArgoCD is installed, set the admin password explicitly.  
If you skip this step, ArgoCD may continue using the generated initial secret.

Linux/macOS examples:

```bash
# Example 1: use default password (EasyDeploy2026) for dev
cd ~/BasePlate-Infra/scripts
ENV=dev bash set-argocd-password.sh

# Example 2: set a custom password for prod
ENV=prod bash set-argocd-password.sh 'MyStrongPassword123!'
```

PowerShell examples:

```powershell
# Example 1: default password for dev
cd .\BasePlate-Infra\scripts
.\set-argocd-password.ps1

# Example 2: custom password for prod
.\set-argocd-password.ps1 "MyStrongPassword123!" "prod"
```

Verification:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret
kubectl -n argocd rollout status deploy/argocd-server
```

### Grafana password bootstrap

Set Grafana admin credentials after monitoring is synced.

Quick runtime update (immediate):

```bash
kubectl -n monitoring create secret generic monitoring-grafana \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<GRAFANA_PASSWORD>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n monitoring rollout restart deploy/monitoring-grafana
kubectl -n monitoring rollout status deploy/monitoring-grafana
```

Permanent GitOps update (recommended):

```bash
# Update the value file for your environment:
#   dev/monitoring/values/kube-prometheus-stack-values.yaml
#   prod/monitoring/values/kube-prometheus-stack-values.yaml
#
# Example key:
# grafana:
#   adminPassword: <GRAFANA_PASSWORD>
```

Verification:

```bash
kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n monitoring get secret monitoring-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
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
