#!/bin/bash
set -euo pipefail

VAULT_VERSION="${VAULT_VERSION:-1.19.0}"

echo "=== Installing dependencies ==="
sudo apt-get update && sudo apt-get install -y unzip curl

echo "=== Installing Vault ${VAULT_VERSION} ==="
curl -fsSL https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip -o /tmp/vault.zip
unzip -o /tmp/vault.zip -d /tmp
sudo mv /tmp/vault /usr/local/bin/vault
sudo chmod +x /usr/local/bin/vault
rm /tmp/vault.zip

vault --version

echo "=== Creating vault user and directories ==="
sudo useradd --system --home /etc/vault.d --shell /bin/false vault 2>/dev/null || true
sudo mkdir -p /opt/vault/data /etc/vault.d/tls
sudo chown -R vault:vault /opt/vault /etc/vault.d

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Copying config ==="
sudo cp "${SCRIPT_DIR}/vault.hcl" /etc/vault.d/vault.hcl
sudo chown vault:vault /etc/vault.d/vault.hcl

echo "=== Installing systemd service ==="
sudo cp "${SCRIPT_DIR}/vault.service" /etc/systemd/system/vault.service
sudo systemctl daemon-reload
sudo systemctl enable vault

echo ""
echo "=== Next steps ==="
echo "  1. Place TLS certs: /etc/vault.d/tls/fullchain.pem + privkey.pem"
echo "  2. sudo systemctl start vault"
echo "  3. export VAULT_ADDR=https://vault.easysolution.work"
echo "  4. bash scripts/init-vault.sh"
