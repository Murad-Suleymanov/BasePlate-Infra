#!/usr/bin/env bash
# Bootstrap a kubeadm control-plane (+ common post-init steps from docs/cluster-kubeadm-installation.md).
# Intended for Ubuntu 22.04/24.04. Run with sudo for phases that install packages / run kubeadm.
#
# Usage:
#   sudo ./bootstrap-kubeadm-control-plane.sh <phase>
#   sudo BOOTSTRAP_PHASE=all ./bootstrap-kubeadm-control-plane.sh
#
# Phases:
#   node        — OS prep: swap off, kernel modules, sysctl (doc §1)
#   containerd — install + configure containerd (doc §2)
#   kubernetes — kubelet, kubeadm, kubectl from pkgs.k8s.io (doc §3)
#   init        — kubeadm init, ~/.kube/config, save join command (doc §4)
#   cni         — Calico + Felix metrics (doc §4)
#   addons      — local-path SC, Gateway API CRDs, Prometheus CRDs, Argo CD (doc §6–8)
#   all         — node → containerd → kubernetes → init → cni → addons
#
# Environment (optional):
#   K8S_VERSION=1.30          — Kubernetes apt repo version
#   POD_CIDR=192.168.0.0/16   — must match Calico manifest expectations
#   CALICO_VERSION=v3.28.1
#   APISERVER_ADVERTISE_ADDRESS= — passed to kubeadm init when set
#   REMOVE_CONTROL_PLANE_TAINT=1 — single-node / dev: allow pods on control-plane
#   SKIP_ADDONS=1            — with `all`, skip addons phase
#
# After `init`, join line is saved to JOIN_CMD_FILE (default /root/kubeadm-join.sh). Workers: see scripts/bootstrap-kubeadm-worker.sh

set -euo pipefail

PHASE="${1:-${BOOTSTRAP_PHASE:-}}"

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run this phase as root (sudo)."; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

K8S_VERSION="${K8S_VERSION:-1.30}"
POD_CIDR="${POD_CIDR:-192.168.0.0/16}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.1}"
JOIN_CMD_FILE="${JOIN_CMD_FILE:-/root/kubeadm-join.sh}"

phase_node() {
  need_root
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https jq git

  swapoff -a || true
  if grep -q ' swap ' /etc/fstab; then
    sed -i '/ swap / s/^/#/' /etc/fstab
  fi

  cat <<'EOF' | tee /etc/modules-load.d/k8s.conf >/dev/null
overlay
br_netfilter
EOF
  modprobe overlay 2>/dev/null || true
  modprobe br_netfilter 2>/dev/null || true

  cat <<'EOF' | tee /etc/sysctl.d/k8s.conf >/dev/null
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
  sysctl --system
  echo "OK: phase node"
}

phase_containerd() {
  need_root
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y containerd
  mkdir -p /etc/containerd
  containerd config default | tee /etc/containerd/config.toml >/dev/null
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
  systemctl enable containerd
  echo "OK: phase containerd"
}

phase_kubernetes() {
  need_root
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
    | tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
  apt-get update -y
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl || true
  echo "OK: phase kubernetes (packages)"
}

phase_init() {
  need_root
  [[ -f /etc/kubernetes/admin.conf ]] && die "Already initialized (/etc/kubernetes/admin.conf exists). Skip init or reset cluster."

  INIT_ARGS=(init "--pod-network-cidr=${POD_CIDR}")
  if [[ -n "${APISERVER_ADVERTISE_ADDRESS:-}" ]]; then
    INIT_ARGS+=(--apiserver-advertise-address="${APISERVER_ADVERTISE_ADDRESS}")
  fi

  kubeadm "${INIT_ARGS[@]}"

  local kube_home="/root/.kube"
  if [[ -n "${SUDO_USER:-}" && -d "/home/${SUDO_USER}" ]]; then
    kube_home="/home/${SUDO_USER}/.kube"
    mkdir -p "${kube_home}"
    cp /etc/kubernetes/admin.conf "${kube_home}/config"
    chown -R "${SUDO_USER}:${SUDO_USER}" "${kube_home}"
    echo "Also copied admin.conf to ${kube_home}/config"
  else
    mkdir -p /root/.kube
    cp /etc/kubernetes/admin.conf /root/.kube/config
  fi

  kubeadm token create --print-join-command | tee "${JOIN_CMD_FILE}" >/dev/null
  chmod 600 "${JOIN_CMD_FILE}" 2>/dev/null || true
  echo "Join command saved: ${JOIN_CMD_FILE}"
  echo "OK: phase init"
}

phase_cni() {
  need_root
  export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  kubectl -n kube-system set env daemonset/calico-node FELIX_PROMETHEUSMETRICSENABLED=true
  kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
  kubectl get nodes -o wide

  if [[ "${REMOVE_CONTROL_PLANE_TAINT:-}" == "1" ]]; then
    kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
    echo "OK: removed control-plane NoSchedule taint (single-node / dev)"
  fi
  echo "OK: phase cni"
}

phase_addons() {
  need_root
  export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true

  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl apply --server-side --force-conflicts -f \
    https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml

  [[ -f "${INFRA_ROOT}/install-gateway-api-crds.sh" ]] || die "Missing ${INFRA_ROOT}/install-gateway-api-crds.sh (clone BasePlate-Infra repo)."
  [[ -f "${INFRA_ROOT}/install-kube-prometheus-crds.sh" ]] || die "Missing ${INFRA_ROOT}/install-kube-prometheus-crds.sh"

  bash "${INFRA_ROOT}/install-gateway-api-crds.sh"
  bash "${INFRA_ROOT}/install-kube-prometheus-crds.sh"

  kubectl get crd httproutes.gateway.networking.k8s.io
  kubectl get crd applicationsets.argoproj.io
  kubectl get crd servicemonitors.monitoring.coreos.com
  kubectl get sc
  echo "OK: phase addons"
}

run_phase() {
  case "$1" in
    node) phase_node ;;
    containerd) phase_containerd ;;
    kubernetes) phase_kubernetes ;;
    init) phase_init ;;
    cni) phase_cni ;;
    addons) phase_addons ;;
    *) die "Unknown phase: $1 (use: node|containerd|kubernetes|init|cni|addons|all)" ;;
  esac
}

if [[ -z "${PHASE}" ]]; then
  cat <<'USAGE'
Usage:
  sudo ./bootstrap-kubeadm-control-plane.sh <phase>

Phases: node | containerd | kubernetes | init | cni | addons | all

Examples:
  sudo ./bootstrap-kubeadm-control-plane.sh all
  sudo REMOVE_CONTROL_PLANE_TAINT=1 ./bootstrap-kubeadm-control-plane.sh all
  sudo ./bootstrap-kubeadm-control-plane.sh node
  sudo ./bootstrap-kubeadm-control-plane.sh init
USAGE
  exit 1
fi

if [[ "${PHASE}" == "all" ]]; then
  need_root
  run_phase node
  run_phase containerd
  run_phase kubernetes
  run_phase init
  run_phase cni
  if [[ "${SKIP_ADDONS:-}" != "1" ]]; then
    run_phase addons
  else
    echo "SKIP_ADDONS=1 — skipping addons"
  fi
  echo "DONE: all phases. Next: workers → scripts/bootstrap-kubeadm-worker.sh; secrets + ArgoCD apps → docs/cluster-kubeadm-installation.md §9–10."
else
  run_phase "${PHASE}"
fi
