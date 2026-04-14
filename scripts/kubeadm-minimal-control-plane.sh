#!/usr/bin/env bash
# Minimal Kubernetes control-plane: kubeadm init + Calico only.
# Ubuntu 22.04/24.04. Run: sudo ./kubeadm-minimal-control-plane.sh
#
# Optional env:
#   K8S_VERSION=1.30
#   POD_CIDR=192.168.0.0/16
#   APISERVER_ADVERTISE_ADDRESS=1.2.3.4
#   SKIP_CNI=1          — only kubeadm init + kubeconfig (node stays NotReady)
#   REMOVE_CP_TAINT=1   — allow scheduling on control-plane (single-node dev)

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
K8S_VERSION="${K8S_VERSION:-1.30}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.1}"

echo "=== 1) OS / kernel ==="
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https
swapoff -a 2>/dev/null || true
sed -i '/ swap / s/^/#/' /etc/fstab 2>/dev/null || true
tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
tee /etc/sysctl.d/k8s.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system

echo "=== 2) containerd ==="
apt-get install -y containerd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml >/dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

echo "=== 3) kubeadm kubelet kubectl ==="
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl 2>/dev/null || true

echo "=== 4) kubeadm init ==="
if [[ -f /etc/kubernetes/admin.conf ]]; then
  echo "Already inited (/etc/kubernetes/admin.conf exists). Exit or kubeadm reset first."
  exit 1
fi
INIT=(kubeadm init "--pod-network-cidr=${POD_CIDR}")
[[ -n "${APISERVER_ADVERTISE_ADDRESS:-}" ]] && INIT+=(--apiserver-advertise-address="${APISERVER_ADVERTISE_ADDRESS}")
"${INIT[@]}"

mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}" ]]; then
  install -d -m 0700 -o "${SUDO_USER}" -g "${SUDO_USER}" "/home/${SUDO_USER}/.kube"
  install -m 0600 -o "${SUDO_USER}" -g "${SUDO_USER}" /etc/kubernetes/admin.conf "/home/${SUDO_USER}/.kube/config"
fi
export KUBECONFIG=/etc/kubernetes/admin.conf

kubeadm token create --print-join-command | tee /root/kubeadm-join.sh >/dev/null
chmod 600 /root/kubeadm-join.sh
echo "Join command: /root/kubeadm-join.sh"

if [[ "${SKIP_CNI:-}" == "1" ]]; then
  echo "SKIP_CNI=1 — no CNI; node will be NotReady until you install a network plugin."
else
  echo "=== 5) Calico CNI ==="
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s || true
fi

if [[ "${REMOVE_CP_TAINT:-}" == "1" ]]; then
  kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
fi

kubectl get nodes -o wide
echo "Done. kubectl: export KUBECONFIG=/etc/kubernetes/admin.conf   or use ~/.kube/config"
echo "Workers: copy /root/kubeadm-join.sh then  sudo ./scripts/kubeadm-minimal-worker.sh ./join.txt"
