#!/usr/bin/env bash
# Prepare each worker (Ubuntu) and join the cluster with kubeadm.
# Run only AFTER the control-plane has finished init + CNI (Calico), so the API is reachable.
# Use the same Kubernetes minor version as the control-plane (K8S_VERSION).
#
# On control-plane (root):
#   cat /root/kubeadm-join.sh
# Copy that single line to a file on the worker, e.g. ~/join.txt, or use KUBEADM_JOIN_CMD.
#
# Usage:
#   sudo ./bootstrap-kubeadm-worker.sh /path/to/join-one-line.txt
#   sudo KUBEADM_JOIN_CMD='kubeadm join ...' ./bootstrap-kubeadm-worker.sh
#
# Environment:
#   K8S_VERSION=1.30  — must match control-plane packages

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)."; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROL_PLANE_SCRIPT="${SCRIPT_DIR}/bootstrap-kubeadm-control-plane.sh"
export K8S_VERSION="${K8S_VERSION:-1.30}"

need_root
[[ -f "${CONTROL_PLANE_SCRIPT}" ]] || die "Missing ${CONTROL_PLANE_SCRIPT}"

for phase in node containerd kubernetes; do
  echo "=== Worker prep: ${phase} ==="
  bash "${CONTROL_PLANE_SCRIPT}" "${phase}"
done

JOIN_LINE=""
if [[ -n "${KUBEADM_JOIN_CMD:-}" ]]; then
  JOIN_LINE="${KUBEADM_JOIN_CMD}"
elif [[ "${1:-}" != "" ]]; then
  [[ -f "$1" ]] || die "Not a file: $1"
  JOIN_LINE="$(tr -d '\r' < "$1" | sed '/^\s*$/d' | head -n1)"
else
  die "Provide join line: either path to a one-line file (output of kubeadm token create --print-join-command) or set KUBEADM_JOIN_CMD='kubeadm join ...'"
fi

[[ -n "${JOIN_LINE}" ]] || die "Empty join command"
echo "=== kubeadm join ==="
# shellcheck disable=SC2086
eval "${JOIN_LINE}"

echo "OK: worker joined. On control-plane: kubectl get nodes -o wide"
