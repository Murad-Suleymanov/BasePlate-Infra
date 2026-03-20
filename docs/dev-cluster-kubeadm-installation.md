# Dev Cluster Full Installation (kubeadm)

Bu sənəd yeni serverdə **dev cluster**-i sıfırdan qaldırmaq üçündür.  
Məqsəd: `BasePlate-Infra` + `Easy-Deploy` stack-i tam işlək vəziyyətə gətirmək.

## 0) Scope

- OS: Ubuntu 22.04/24.04
- Runtime: containerd
- Kubernetes: kubeadm
- GitOps: ArgoCD
- Infra repo: `BasePlate-Infra`
- Platform repo: `Easy-Deploy`

---

## 1) OS hazırlığı və daxili paketlər

```bash
sudo apt update && sudo apt -y upgrade
sudo apt -y install ca-certificates curl gnupg lsb-release apt-transport-https jq git
```

Swap söndür:

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

Kernel modulları və sysctl:

```bash
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

---

## 2) containerd quraşdırılması

```bash
sudo apt -y install containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

Yoxlama:

```bash
sudo systemctl status containerd --no-pager
```

---

## 3) kubeadm/kubelet/kubectl quraşdırılması

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt -y install kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

---

## 4) Control-plane init (kubeadm)

```bash
sudo kubeadm init --pod-network-cidr=192.168.0.0/16
```

Kubectl config:

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

---

## 5) CNI (Calico)

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml
kubectl get nodes -o wide
```

---

## 6) Repositories clone

```bash
cd ~
git clone https://github.com/Murad-Suleymanov/BasePlate-Infra.git
git clone https://github.com/Murad-Suleymanov/BasePlate.git
```

---

## 7) ArgoCD (CRD-lərlə birlikdə)

```bash
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

`applicationsets.argoproj.io` CRD üçün (böyük CRD annotation limitinə görə server-side apply):

```bash
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml
kubectl get crd applicationsets.argoproj.io
```

---

## 8) Infra dependency CRD-lər

### 8.1 Gateway API CRD-lər

```bash
cd ~/BasePlate-Infra
bash install-gateway-api-crds.sh
```

### 8.2 Prometheus Operator CRD-lər

```bash
cd ~/BasePlate-Infra
bash install-kube-prometheus-crds.sh
```

---

## 9) Lazımi secret-lər (dev cluster)

### 9.1 Cloudflare token (external-dns üçün)

```bash
kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-dns create secret generic cloudflare-api-token \
  --from-literal=cloudflare_api_token='<CLOUDFLARE_TOKEN>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 9.2 GitHub pipeline secret (operator üçün)

```bash
cd ~/BasePlate-Infra/scripts
GITHUB_TOKEN=<GITHUB_TOKEN> ./bootstrap-pipeline-secret.sh
kubectl -n easy-deploy-system rollout restart deployment easy-deploy-operator
```

---

## 10) Sync order (mütləq sıra)

### 10.1 Infra root

```bash
cd ~/BasePlate-Infra
kubectl apply -f argocd/dev/application-root.yaml
```

### 10.2 Platform root

```bash
cd ~/Easy-Deploy
kubectl apply -f argocd/dev/application-root.yaml
```

---

## 11) Post-deploy verification (5 komanda)

```bash
kubectl -n argocd get applications
kubectl get pods -n nginx-gateway && kubectl get pods -n external-dns && kubectl get pods -n cert-manager
kubectl get httproute -A
kubectl -n external-dns logs deploy/external-dns --tail=120
kubectl -n easy-deploy-system get deploy easy-deploy-operator -o wide
```

---

## 12) Tez-tez rast gəlinən xətalar

### A) `no matches for kind "ApplicationSet"`

Səbəb: `applicationsets.argoproj.io` CRD yoxdur.

```bash
kubectl apply --server-side --force-conflicts -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml
```

### B) `metadata.annotations: Too long` (CRD apply zamanı)

Səbəb: client-side apply `last-applied-configuration` annotation limiti.

Həll: server-side apply istifadə et (yuxarıdakı komanda).

### C) `no matches for kind "HTTPRoute"`

Səbəb: Gateway API CRD quraşdırılmayıb.

```bash
bash ~/BasePlate-Infra/install-gateway-api-crds.sh
```

### D) App `OutOfSync/Missing` qalır

```bash
kubectl -n argocd describe application <app-name>
kubectl -n argocd logs deploy/argocd-application-controller --tail=200 | grep -i <app-name>
```

---

## 13) Qeyd

- Dev və prod ayrı cluster olduqda eyni adlar problem yaratmır.
- Dev DNS target IP/URL-lər dev konfiqdə ayrıca saxlanılmalıdır.
- `BasePlate-Infra` və `Easy-Deploy` root-ları ayrı apply olunur; infra həmişə birinci.
