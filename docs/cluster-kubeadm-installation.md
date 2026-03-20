# Cluster Runbook (kubeadm, no-surprise flow)

Bu sənəd real qarşılaşdığımız problemlər əsasında hazırlanıb ki növbəti cluster qurulumunda vaxt itirməyək.

Məqsəd: istənilən cluster-i bir dəfəyə `Synced + Healthy` vəziyyətinə gətirmək.

## 0) Scope

- OS: Ubuntu 22.04/24.04
- Runtime: containerd
- Kubernetes: kubeadm
- GitOps: ArgoCD
- Repositories:
  - `BasePlate-Infra`
  - `Easy-Deploy`
- Environment selector:
  - `ENV=dev` və ya `ENV=prod`

---

## 1) Node hazırlığı (OS + kernel)

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

## 2) containerd

```bash
sudo apt -y install containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

## 3) kubeadm/kubelet/kubectl

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

## 5) Repositories clone

```bash
cd ~
git clone https://github.com/Murad-Suleymanov/BasePlate-Infra.git
git clone https://github.com/Murad-Suleymanov/Easy-Deploy.git
```

## 6) ArgoCD install (CRD-safe)

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml
kubectl get crd applicationsets.argoproj.io
```

## 7) Cluster-level dependency CRD-lər (mütləq)

```bash
cd ~/BasePlate-Infra
bash install-gateway-api-crds.sh
bash install-kube-prometheus-crds.sh

kubectl get crd httproutes.gateway.networking.k8s.io
kubectl get crd applicationsets.argoproj.io
kubectl get crd servicemonitors.monitoring.coreos.com
```

## 8) StorageClass (Grafana Pending olmasın)

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl get sc
```

## 9) Namespace və secret-lər (sync-dən əvvəl)

```bash
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace easy-deploy-system --dry-run=client -o yaml | kubectl apply -f -
```

Cloudflare token iki namespace-də:

```bash
kubectl -n external-dns create secret generic cloudflare-api-token \
  --from-literal=cloudflare_api_token='<CLOUDFLARE_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n cert-manager create secret generic cloudflare-api-token \
  --from-literal=cloudflare_api_token='<CLOUDFLARE_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Pipeline secret:

```bash
cd ~/BasePlate-Infra/scripts
GITHUB_TOKEN=<GITHUB_TOKEN> ./bootstrap-pipeline-secret.sh
```

## 10) Sync order (mütləq sıra)

```bash
export ENV=dev   # dev və ya prod

cd ~/BasePlate-Infra
kubectl apply -f argocd/${ENV}/application-root.yaml

cd ~/Easy-Deploy
kubectl apply -f argocd/${ENV}/application-root.yaml
```

## 11) Stabilizasiya komandaları

```bash
kubectl -n argocd get applications
kubectl get pods -n cert-manager
kubectl get pods -n monitoring
kubectl get pods -n external-dns
kubectl get httproute -A
kubectl get clusterissuer
```

Certificate propagation:

```bash
kubectl -n nginx-gateway get certificate
dig TXT _acme-challenge.easysolution.work @1.1.1.1 +short
dig TXT _acme-challenge.easysolution.work @8.8.8.8 +short
```

## 12) Quick fix map

- `no matches for kind "ApplicationSet"` -> `applicationset-crd.yaml` server-side apply et.
- `metadata.annotations: Too long` -> CRD-ləri client-side yox, server-side apply et.
- `no matches for kind "HTTPRoute"` -> `install-gateway-api-crds.sh` işlə.
- `cloudflare-api-token not found` -> token-i `cert-manager` namespace-də də yarat.
- Grafana `Pending` + PVC `local-path` -> `local-path-provisioner` qur.
- App `Synced` amma `Degraded` -> hard refresh + manual sync:

```bash
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd patch application <app> --type merge -p '{"operation":{"sync":{"prune":true}}}'
```

- ArgoCD controller restart:

```bash
kubectl -n argocd rollout restart statefulset/argocd-application-controller
```

## 13) Final success criteria

- `kubectl -n argocd get applications` -> əsas app-lar `Synced + Healthy`
- `kubectl -n nginx-gateway get certificate` -> wildcard cert `Ready=True`
- `kubectl get clusterissuer` -> `letsencrypt` və `letsencrypt-staging` `True`
- `kubectl -n external-dns get pods` -> `Running`
- `kubectl -n easy-deploy-system get deploy easy-deploy-operator` -> `READY 1/1`
