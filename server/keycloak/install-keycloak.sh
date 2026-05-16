#!/bin/bash
set -euo pipefail

KEYCLOAK_HOSTNAME="${1:?Usage: $0 <keycloak-hostname> <admin-password>}"
ADMIN_PASSWORD="${2:?Usage: $0 <keycloak-hostname> <admin-password>}"
KEYCLOAK_VERSION="26.3.2"
INSTALL_DIR="/opt/keycloak"

echo "=== Installing Keycloak ${KEYCLOAK_VERSION} ==="

if ! java -version 2>&1 | grep -q "21"; then
  echo "--- Java 21 not found, installing..."
  apt-get update && apt-get install -y openjdk-21-jdk-headless
fi

if [ -d "${INSTALL_DIR}" ]; then
  echo "ERROR: ${INSTALL_DIR} already exists."
  echo "       Remove it first for a clean install: rm -rf ${INSTALL_DIR}"
  exit 1
fi

echo "--- Downloading Keycloak ${KEYCLOAK_VERSION}..."
cd /tmp
curl -fSL -o keycloak.tar.gz \
  "https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz"

echo "--- Extracting..."
tar -xzf keycloak.tar.gz
mv "keycloak-${KEYCLOAK_VERSION}" "${INSTALL_DIR}"
rm keycloak.tar.gz

groupadd -r keycloak 2>/dev/null || true
useradd -r -g keycloak -d "${INSTALL_DIR}" -s /sbin/nologin keycloak 2>/dev/null || true
chown -R keycloak:keycloak "${INSTALL_DIR}"

echo "--- Creating systemd service..."
cat > /etc/systemd/system/keycloak.service <<EOF
[Unit]
Description=Keycloak Identity Provider
After=network.target

[Service]
Type=exec
User=keycloak
Group=keycloak
WorkingDirectory=${INSTALL_DIR}
Environment=KC_BOOTSTRAP_ADMIN_USERNAME=admin
Environment=KC_BOOTSTRAP_ADMIN_PASSWORD=${ADMIN_PASSWORD}
Environment=KC_HOSTNAME=https://${KEYCLOAK_HOSTNAME}
Environment=KC_PROXY_HEADERS=xforwarded
Environment=KC_HTTP_ENABLED=true
Environment=KC_HTTP_PORT=8080
ExecStart=${INSTALL_DIR}/bin/kc.sh start --metrics-enabled=true --health-enabled=true
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "--- Building optimized Keycloak..."
sudo -u keycloak "${INSTALL_DIR}/bin/kc.sh" build

echo "--- Starting Keycloak..."
systemctl daemon-reload
systemctl enable keycloak
systemctl start keycloak

echo "=== Configuring Nginx for Keycloak ==="
if ! command -v nginx &>/dev/null; then
  apt-get update && apt-get install -y nginx
fi

cat > /etc/nginx/sites-available/keycloak.conf <<'NGINX'
server {
    listen 443 ssl;
    server_name keycloak.easysolution.work;

    ssl_certificate     /etc/ssl/easysolution/fullchain.pem;
    ssl_certificate_key /etc/ssl/easysolution/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location /metrics {
        proxy_pass         http://127.0.0.1:9000/metrics;
        proxy_set_header   Host $host;
    }

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_set_header   X-Forwarded-Port  443;
        proxy_read_timeout 300s;
    }
}

server {
    listen 80;
    server_name keycloak.easysolution.work;
    return 301 https://$host$request_uri;
}
NGINX

ln -sf /etc/nginx/sites-available/keycloak.conf /etc/nginx/sites-enabled/keycloak.conf

nginx -t
systemctl enable nginx
if systemctl is-active --quiet nginx; then
  systemctl reload nginx
  echo "Nginx reloaded (keycloak block added)"
else
  systemctl start nginx
  echo "Nginx started"
fi

echo ""
echo "=== Keycloak ${KEYCLOAK_VERSION} installed ==="
echo "URL:     https://${KEYCLOAK_HOSTNAME}"
echo "Admin:   admin / ${ADMIN_PASSWORD}"
echo "Logs:    journalctl -u keycloak -f"
echo ""
echo "Wait ~40 seconds for Keycloak to fully start, then:"
echo "  bash configure-clients.sh ${KEYCLOAK_HOSTNAME} <admin-pass> <kiali-host> <jaeger-host>"
