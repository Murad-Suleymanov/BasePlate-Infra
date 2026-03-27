#!/bin/bash
set -euo pipefail

VAULT_VERSION="${VAULT_VERSION:-1.19.0}"
VAULT_HOSTNAME="vault.easysolution.work"

echo "=== Installing dependencies ==="
apt-get update && apt-get install -y unzip curl nginx

echo "=== Installing Vault ${VAULT_VERSION} ==="
curl -fsSL "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_amd64.zip" -o /tmp/vault.zip
unzip -o /tmp/vault.zip -d /tmp
mv /tmp/vault /usr/local/bin/vault
chmod +x /usr/local/bin/vault
rm /tmp/vault.zip
vault --version

echo "=== Creating vault user and directories ==="
useradd --system --home /etc/vault.d --shell /bin/false vault 2>/dev/null || true
mkdir -p /opt/vault/data /etc/vault.d/tls
chown -R vault:vault /opt/vault /etc/vault.d

echo "=== Writing vault.hcl ==="
cat > /etc/vault.d/vault.hcl <<'EOF'
storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-prod-1"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
  telemetry {
    unauthenticated_metrics_access = true
  }
}

api_addr     = "https://vault.easysolution.work"
cluster_addr = "https://vault.easysolution.work:8201"

ui = true
disable_mlock = true

max_lease_ttl     = "768h"
default_lease_ttl = "768h"

telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
EOF
chown vault:vault /etc/vault.d/vault.hcl

echo "=== Writing vault.service ==="
cat > /etc/systemd/system/vault.service <<'EOF'
[Unit]
Description=HashiCorp Vault
Documentation=https://www.vaultproject.io/docs
After=network-online.target
Wants=network-online.target

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vault

echo "=== Configuring Nginx for Vault ==="
cat > /etc/nginx/sites-available/vault.conf <<'NGINX'
server {
    listen 443 ssl;
    server_name vault.easysolution.work;

    ssl_certificate     /etc/ssl/easysolution/fullchain.pem;
    ssl_certificate_key /etc/ssl/easysolution/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    proxy_buffer_size          128k;
    proxy_buffers              8 256k;
    proxy_busy_buffers_size    256k;

    location / {
        proxy_pass         http://127.0.0.1:8200;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
    }
}

server {
    listen 80;
    server_name vault.easysolution.work;
    return 301 https://$host$request_uri;
}
NGINX

ln -sf /etc/nginx/sites-available/vault.conf /etc/nginx/sites-enabled/vault.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx

echo ""
echo "=== Vault quraşdırıldı ==="
echo ""
echo "Növbəti addımlar:"
echo "  1. TLS sertifikat qoy: /etc/ssl/easysolution/fullchain.pem + privkey.pem"
echo "  2. systemctl start vault"
echo "  3. systemctl start nginx"
echo "  4. export VAULT_ADDR=https://${VAULT_HOSTNAME}"
echo "  5. bash init-vault.sh ${VAULT_HOSTNAME}"
