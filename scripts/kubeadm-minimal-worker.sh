#!/usr/bin/env bash
# Minimal worker: same prep as control-plane (OS, containerd, kubelet/kubeadm/kubectl) then kubeadm join only.
# Prereq: control-plane is up with CNI (e.g. kubeadm-minimal-control-plane.sh). Same K8S_VERSION as control-plane.
#
# Usage:
#   sudo ./kubeadm-minimal-worker.sh /path/to/join-one-line.txt
#   sudo KUBEADM_JOIN_CMD='kubeadm join ...' ./kubeadm-minimal-worker.sh
#
# On control-plane: cat /root/kubeadm-join.sh   (or kubeadm token create --print-join-command)

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Run as root: sudo $0" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
K8S_VERSION="${K8S_VERSION:-1.30}"

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "This host already has /etc/kubernetes/kubelet.conf (likely already joined). Exit or kubeadm reset first." >&2
  exit 1
fi

JOIN_LINE=""
if [[ -n "${KUBEADM_JOIN_CMD:-}" ]]; then
  JOIN_LINE="${KUBEADM_JOIN_CMD}"
elif [[ "${1:-}" != "" ]]; then
  [[ -f "$1" ]] || { echo "Not a file: $1" >&2; exit 1; }
  JOIN_LINE="$(tr -d '\r' < "$1" | sed '/^\s*$/d' | head -n1)"
else
  echo "Usage: sudo $0 /path/to/join-one-line.txt" >&2
  echo "   or: sudo KUBEADM_JOIN_CMD='kubeadm join ...' $0" >&2
  exit 1
fi
[[ -n "${JOIN_LINE}" ]] || { echo "Empty join command" >&2; exit 1; }

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
systemctl enable --now kubelet

echo "=== 4) kubeadm join ==="
# shellcheck disable=SC2086
eval "${JOIN_LINE}"

echo "Done. On control-plane: kubectl get nodes -o wide"
