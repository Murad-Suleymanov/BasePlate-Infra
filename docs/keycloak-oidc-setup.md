# Keycloak OIDC Authentication Setup for Jaeger & Kiali

Complete guide for setting up Keycloak and Vault on bare-metal, configuring Nginx reverse proxies, creating OIDC clients, and integrating authentication with Jaeger (via OAuth2 Proxy) and Kiali in Kubernetes.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Part 1: TLS Certificates](#part-1-tls-certificates)
- [Part 2: Vault Installation & Nginx](#part-2-vault-installation--nginx)
- [Part 3: Vault Initialization & Configuration](#part-3-vault-initialization--configuration)
- [Part 4: Keycloak Installation & Nginx](#part-4-keycloak-installation--nginx)
- [Part 5: Keycloak Realm & Client Setup](#part-5-keycloak-realm--client-setup)
- [Part 6: Vault Secrets for OAuth2 Proxy](#part-6-vault-secrets-for-oauth2-proxy)
- [Part 7: Kubernetes Secret Sync & Verification](#part-7-kubernetes-secret-sync--verification)
- [Part 8: Kiali OpenID Configuration](#part-8-kiali-openid-configuration)
- [Part 9: Verification](#part-9-verification)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
                          ┌──────────────────────────────────┐
                          │     Bare-Metal Server             │
                          │                                   │
  User ──► Nginx :443 ──►│  keycloak.easysolution.work       │
           (TLS)          │    └─► Keycloak :8080             │
                          │                                   │
  User ──► Nginx :443 ──►│  vault.easysolution.work          │
           (TLS)          │    └─► Vault :8200                │
                          └──────────────────────────────────┘

                          ┌──────────────────────────────────┐
                          │     Kubernetes Cluster            │
                          │                                   │
  User ──► NGINX GW ────►│  jaeger.easysolution.work         │
                          │    └─► OAuth2 Proxy :4180         │
                          │         ├─► Keycloak (OIDC)       │
                          │         └─► Jaeger :16686         │
                          │                                   │
  User ──► NGINX GW ────►│  kiali.easysolution.work          │
                          │    └─► Kiali :20001               │
                          │         └─► Keycloak (OIDC)       │
                          └──────────────────────────────────┘

  Secrets Flow:
    Vault ──► Vault Secrets Operator ──► K8s Secret (keycloak-secrets)
                                              │
                                              ▼
                                       OAuth2 Proxy Pod
```

**Keycloak** and **Vault** run as bare-metal services on the server, fronted by Nginx reverse proxies with TLS.

**Jaeger** uses an OAuth2 Proxy deployment in Kubernetes that handles the OIDC authorization code flow. The proxy authenticates users via Keycloak, then forwards authenticated requests to Jaeger.

**Kiali** has built-in OpenID Connect support with `disable_rbac: true`, meaning it authenticates users via Keycloak but uses its own Kubernetes ServiceAccount for API access.

---

## Prerequisites

- A Linux server (Ubuntu/Debian) with root access
- DNS records pointing to the server:
  - `keycloak.easysolution.work` → server IP
  - `vault.easysolution.work` → server IP
- DNS records pointing to the Kubernetes cluster ingress IP:
  - `jaeger.easysolution.work` → cluster ingress IP
  - `kiali.easysolution.work` → cluster ingress IP
- A running Kubernetes cluster with:
  - NGINX Gateway Fabric
  - Vault Secrets Operator
  - ArgoCD
  - Jaeger (Helm chart)
  - Kiali (Helm chart)
  - Istio

---

## Part 1: TLS Certificates

Both Keycloak and Vault Nginx configs expect TLS certificates at:

```
/etc/ssl/easysolution/fullchain.pem
/etc/ssl/easysolution/privkey.pem
```

### 1.1 Obtain Certificates (Let's Encrypt with Certbot)

```bash
apt-get update && apt-get install -y certbot

certbot certonly --standalone \
  -d keycloak.easysolution.work \
  -d vault.easysolution.work \
  --agree-tos --no-eff-email \
  -m your-email@example.com
```

### 1.2 Copy Certificates to the Expected Path

```bash
mkdir -p /etc/ssl/easysolution

cp /etc/letsencrypt/live/keycloak.easysolution.work/fullchain.pem /etc/ssl/easysolution/fullchain.pem
cp /etc/letsencrypt/live/keycloak.easysolution.work/privkey.pem /etc/ssl/easysolution/privkey.pem
```

> If you use a wildcard certificate for `*.easysolution.work`, copy that instead.

### 1.3 Set Up Auto-Renewal

```bash
# Test renewal
certbot renew --dry-run

# Certbot installs a systemd timer automatically.
# Verify:
systemctl list-timers | grep certbot
```

> **Important:** After renewal, you may need to reload Nginx:
> ```bash
> systemctl reload nginx
> ```

---

## Part 2: Vault Installation & Nginx

### 2.1 Run the Install Script

SSH into the server and run:

```bash
cd /path/to/BasePlate-Infra/server/vault
bash install-vault.sh
```

This script:
1. Downloads and installs Vault binary (v1.19.0)
2. Creates the `vault` system user and data directories
3. Writes `/etc/vault.d/vault.hcl` (Raft storage, listener on 127.0.0.1:8200)
4. Creates the `vault.service` systemd unit
5. Configures Nginx reverse proxy for `vault.easysolution.work`

### 2.2 Nginx Configuration Created

The script creates `/etc/nginx/sites-available/vault.conf`:

```nginx
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
```

It is symlinked to `/etc/nginx/sites-enabled/vault.conf`.

### 2.3 Start Services

Make sure TLS certificates are in place (Part 1), then:

```bash
systemctl start vault
systemctl start nginx
```

### 2.4 Verify

```bash
# Check Vault is running
systemctl status vault

# Check Nginx is running
systemctl status nginx

# Check HTTPS access
curl -s https://vault.easysolution.work/v1/sys/health
```

---

## Part 3: Vault Initialization & Configuration

### 3.1 Initialize Vault

```bash
cd /path/to/BasePlate-Infra/server/vault
export VAULT_ADDR=https://vault.easysolution.work
bash init-vault.sh vault.easysolution.work
```

This script:
1. Initializes Vault with 3 unseal keys (threshold: 2)
2. Unseals Vault automatically
3. Enables KV v2 secrets engine at `secret/`
4. Creates initial secret paths with placeholder values
5. Enables Kubernetes auth backends (`kubernetes-prod` and `kubernetes-dev`)

> **CRITICAL:** Save the unseal keys and root token securely. They cannot be recovered.

The script outputs:
```
  Unseal Key 1: <key1>
  Unseal Key 2: <key2>
  Unseal Key 3: <key3>
  Root Token:   hvs.xxxxx
```

### 3.2 Configure Kubernetes Auth

Run this **on each Kubernetes cluster node** (requires `kubectl` access):

```bash
export VAULT_TOKEN="<root-token-from-step-3.1>"

# For production cluster
bash configure-k8s-auth.sh vault.easysolution.work prod https://<k8s-api-server-url>:6443

# For dev cluster
bash configure-k8s-auth.sh vault.easysolution.work dev https://<k8s-api-server-url>:6443
```

This script:
1. Reads the `vault-auth-token` ServiceAccount JWT from the cluster
2. Configures Vault's Kubernetes auth endpoint with the cluster's CA and JWT
3. Creates a policy allowing read access to `secret/data/<env>/*` and `secret/data/istio/*`
4. Creates a role `vault-secrets-operator` bound to the `default` ServiceAccount

> **Prerequisite:** The `vault-auth-token` Secret must exist in the cluster. This is created by the `secrets-config` Helm chart (`charts/secrets-config/templates/vault-auth-token.yaml`). Make sure ArgoCD has synced the `secrets-config` application first.

### 3.3 Update Placeholder Secrets

After initialization, replace the `CHANGE_ME` placeholder values in Vault with real credentials. You can do this via the Vault UI (`https://vault.easysolution.work`) or API:

```bash
export VAULT_TOKEN="<root-token>"

# Example: Update Cloudflare token
curl -sk -X POST "https://vault.easysolution.work/v1/secret/data/prod/cloudflare" \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"data": {"cloudflare_api_token": "<real-token>"}}'
```

---

## Part 4: Keycloak Installation & Nginx

### 4.1 Run the Install Script

SSH into the server and run:

```bash
cd /path/to/BasePlate-Infra/server/keycloak
bash install-keycloak.sh keycloak.easysolution.work "<admin-password>"
```

This script:
1. Installs Java 21 (if not present)
2. Downloads Keycloak v26.3.2
3. Creates the `keycloak` system user
4. Writes a systemd service with environment variables:
   - `KC_HOSTNAME=https://keycloak.easysolution.work`
   - `KC_PROXY_HEADERS=xforwarded` (required for Nginx reverse proxy)
   - `KC_HTTP_PORT=8080`
5. Builds and starts Keycloak
6. Configures Nginx reverse proxy for `keycloak.easysolution.work`

### 4.2 Nginx Configuration Created

The script creates `/etc/nginx/sites-available/keycloak.conf`:

```nginx
server {
    listen 443 ssl;
    server_name keycloak.easysolution.work;

    ssl_certificate     /etc/ssl/easysolution/fullchain.pem;
    ssl_certificate_key /etc/ssl/easysolution/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

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
```

It is symlinked to `/etc/nginx/sites-enabled/keycloak.conf`.

### 4.3 Verify

```bash
# Check Keycloak is running
systemctl status keycloak

# Check logs (Keycloak takes ~40 seconds to fully start)
journalctl -u keycloak -f

# Test HTTPS access
curl -s https://keycloak.easysolution.work/health/ready
```

Expected response: `{"status":"UP"}`

### 4.4 Access Admin Console

Open `https://keycloak.easysolution.work` in a browser and log in with:
- **Username:** `admin`
- **Password:** the password you provided in step 4.1

---

## Part 5: Keycloak Realm & Client Setup

### 5.1 Automated Setup with configure-clients.sh

Wait ~40 seconds after Keycloak starts, then run **on the same server**:

```bash
cd /path/to/BasePlate-Infra/server/keycloak

# Without Vault auto-write:
bash configure-clients.sh keycloak.easysolution.work "<admin-password>" kiali.easysolution.work jaeger.easysolution.work

# With Vault auto-write (recommended):
export VAULT_TOKEN="<vault-root-token>"
bash configure-clients.sh keycloak.easysolution.work "<admin-password>" kiali.easysolution.work jaeger.easysolution.work
```

This script automatically:
1. Creates the `istio` realm
2. Creates the `kiali` client (redirect URI: `https://kiali.easysolution.work/*`)
3. Creates the `jaeger-proxy` client (redirect URI: `https://jaeger.easysolution.work/oauth2/callback`)
4. Creates a `viewer` user with password `viewer123`
5. Generates a cookie secret for OAuth2 Proxy
6. If `VAULT_TOKEN` is set, writes `jaeger-client-secret` and `oauth2-proxy-cookie-secret` to Vault at `secret/istio/keycloak`

The script outputs the client secrets:
```
--- Creating client: kiali
OK (created)
  Client ID:      kiali
  Client Secret:  <secret>

--- Creating client: jaeger-proxy
OK (created)
  Client ID:      jaeger-proxy
  Client Secret:  <secret>
```

### 5.2 Post-Script: Fix Kiali Client Type

The `configure-clients.sh` script creates both clients as **confidential** (`publicClient: false`). The `kiali` client **must be changed to public** because Kiali does not send a client secret during OIDC authentication.

Run on the server:

```bash
TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=<ADMIN_PASSWORD>" \
  -d "grant_type=password" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

KIALI_UUID=$(curl -s "http://localhost:8080/admin/realms/istio/clients?clientId=kiali" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

curl -s -X PUT "http://localhost:8080/admin/realms/istio/clients/$KIALI_UUID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"clientId":"kiali","publicClient":true}'

echo "Kiali client set to public"
```

### 5.3 Post-Script: Set Email Verified for Users

OAuth2 Proxy requires the `email_verified` claim in the ID token to be `true`. The `configure-clients.sh` script does not set this. Fix it:

```bash
USER_ID=$(curl -s "http://localhost:8080/admin/realms/istio/users?email=viewer@easysolution.work" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

curl -s -X PUT "http://localhost:8080/admin/realms/istio/users/$USER_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"emailVerified": true}'

echo "Email verified set for viewer user"
```

> **Important:** Every user who will access Jaeger must have `emailVerified: true`. Without this, OAuth2 Proxy rejects the token with: `email in id_token (...) isn't verified`.

### 5.4 Verify Final Client Configuration

```bash
# Verify jaeger-proxy (must be confidential)
curl -s "http://localhost:8080/admin/realms/istio/clients?clientId=jaeger-proxy" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys,json; c=json.load(sys.stdin)[0]
print('clientId:', c['clientId'])
print('publicClient:', c['publicClient'])           # Must be: False
print('standardFlowEnabled:', c['standardFlowEnabled'])  # Must be: True
print('redirectUris:', c['redirectUris'])
"

# Verify kiali (must be public)
curl -s "http://localhost:8080/admin/realms/istio/clients?clientId=kiali" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys,json; c=json.load(sys.stdin)[0]
print('clientId:', c['clientId'])
print('publicClient:', c['publicClient'])           # Must be: True
print('standardFlowEnabled:', c['standardFlowEnabled'])  # Must be: True
print('redirectUris:', c['redirectUris'])
"
```

Expected:
```
# jaeger-proxy:
publicClient: False

# kiali:
publicClient: True
```

---

## Part 6: Vault Secrets for OAuth2 Proxy

The OAuth2 Proxy requires two secrets stored in Vault at `secret/istio/keycloak`:

| Key | Description | Source |
|-----|-------------|--------|
| `jaeger-client-secret` | The `jaeger-proxy` client secret | Keycloak Credentials tab or `configure-clients.sh` output |
| `oauth2-proxy-cookie-secret` | Random 32-byte string for cookie encryption | `configure-clients.sh` generates this automatically |

### 6.1 If configure-clients.sh Wrote to Vault Automatically

If you ran `configure-clients.sh` with `VAULT_TOKEN` set, secrets are already in Vault. Verify:

```bash
curl -s "https://vault.easysolution.work/v1/secret/data/istio/keycloak" \
  -H "X-Vault-Token: $VAULT_TOKEN" | python3 -c "
import sys,json
data = json.load(sys.stdin)['data']['data']
for k,v in data.items():
    print(f'{k}: {v[:8]}...')
"
```

### 6.2 If Writing to Vault Manually

If `VAULT_TOKEN` was not set, write the secrets manually:

**Option A: Via Vault UI**

1. Open `https://vault.easysolution.work`
2. Navigate to **secret** → **istio** → **keycloak**
3. Set `jaeger-client-secret` to the value from the `configure-clients.sh` output
4. Set `oauth2-proxy-cookie-secret` to a random 32-character string (generate with `openssl rand -base64 32 | head -c 32`)
5. Click **Save**

**Option B: Via Vault API**

```bash
VAULT_TOKEN="<your-vault-token>"

curl -s -X POST "https://vault.easysolution.work/v1/secret/data/istio/keycloak" \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "jaeger-client-secret": "<CLIENT_SECRET_FROM_KEYCLOAK>",
      "oauth2-proxy-cookie-secret": "<RANDOM_32_CHAR_STRING>"
    }
  }'
```

### 6.3 Validate the Client Secret

Test the client secret directly against Keycloak:

```bash
curl -s -X POST "https://keycloak.easysolution.work/realms/istio/protocol/openid-connect/token" \
  -d "client_id=jaeger-proxy" \
  -d "client_secret=<CLIENT_SECRET>" \
  -d "grant_type=client_credentials"
```

- **Correct secret:** `{"error":"unauthorized_client","error_description":"Client not enabled to retrieve service account"}` — the credentials were accepted, this error is expected because service accounts are disabled.
- **Wrong secret:** `{"error":"unauthorized_client","error_description":"Invalid client or Invalid client credentials"}` — the secret does NOT match Keycloak.

---

## Part 7: Kubernetes Secret Sync & Verification

The Vault Secrets Operator automatically syncs `secret/istio/keycloak` from Vault to a Kubernetes Secret named `keycloak-secrets` in the `istio-system` namespace.

This sync is configured in `secrets-config-values.yaml`:

```yaml
keycloak-secrets:
  enabled: true
  name: keycloak-secrets
  namespace: istio-system
  refreshInterval: 1h
  fullPath: istio/keycloak
```

### 7.1 Verify the Kubernetes Secret

```bash
kubectl get secret keycloak-secrets -n istio-system \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```

Expected output:
```
jaeger-client-secret: <same as Vault>
oauth2-proxy-cookie-secret: <same as Vault>
```

### 7.2 Force Re-Sync if Outdated

If the Kubernetes secret doesn't match Vault:

```bash
# Restart the Vault Secrets Operator
kubectl rollout restart deployment -n vault-secrets-operator-system vault-secrets-operator-controller-manager

# Wait 30 seconds
sleep 30

# Verify again
kubectl get secret keycloak-secrets -n istio-system \
  -o go-template='{{range $k,$v := .data}}{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}'
```

### 7.3 Restart OAuth2 Proxy Pod

After the secret is updated, restart the OAuth2 Proxy pod to pick up new values:

```bash
kubectl delete pod -n istio-system -l app.kubernetes.io/name=oauth2-proxy-jaeger
```

---

## Part 8: Kiali OpenID Configuration

### 8.1 Helm Values

The Kiali Helm values file must include `disable_rbac: true` under the `openid` configuration:

```yaml
# prod/kiali/values/kiali-values.yaml (or dev equivalent)
auth:
  strategy: openid
  openid:
    client_id: kiali
    issuer_uri: https://keycloak.easysolution.work/realms/istio
    scopes: [openid, profile, email]
    username_claim: preferred_username
    disable_rbac: true
```

**Key settings explained:**

| Setting | Value | Description |
|---------|-------|-------------|
| `strategy` | `openid` | Use OpenID Connect for authentication |
| `client_id` | `kiali` | Must match the Keycloak client ID |
| `issuer_uri` | `https://keycloak.easysolution.work/realms/istio` | Keycloak OIDC issuer URL |
| `scopes` | `[openid, profile, email]` | OIDC scopes to request |
| `username_claim` | `preferred_username` | Token claim used as the displayed username |
| `disable_rbac` | `true` | **Required.** Kiali uses its own ServiceAccount for K8s API calls instead of the user's OIDC token |

> **Why `disable_rbac: true`?** Without this, Kiali passes the user's OIDC token to the Kubernetes API server for authorization. This requires the kube-apiserver to be configured with `--oidc-issuer-url`, `--oidc-client-id`, etc., which adds significant complexity and risk to the cluster. With `disable_rbac: true`, Kiali authenticates users via Keycloak (for identity) but uses its own ServiceAccount with its existing RBAC permissions for all Kubernetes API operations.

### 8.2 Deploy

Push the changes and let ArgoCD sync:

```bash
git add .
git commit -m "Configure Kiali OpenID with disable_rbac"
git push
```

Verify the ConfigMap was updated:

```bash
kubectl get cm kiali -n istio-system -o yaml | grep "disable_rbac"
```

If ArgoCD hasn't synced yet, restart the Kiali pod after sync:

```bash
kubectl delete pod -n istio-system -l app.kubernetes.io/name=kiali
```

---

## Part 9: Verification

### 9.1 Check All Pods are Running

```bash
kubectl get pods -n istio-system -l app.kubernetes.io/name=oauth2-proxy-jaeger
kubectl get pods -n istio-system -l app.kubernetes.io/name=kiali
```

Both should show `Running` with no restarts.

### 9.2 Test Jaeger

1. Open an **incognito/private** browser window
2. Navigate to `https://jaeger.easysolution.work`
3. You should be automatically redirected to the Keycloak login page
4. Enter credentials (e.g., `viewer@easysolution.work` / `viewer123`)
5. After successful login, you should see the Jaeger UI

### 9.3 Test Kiali

1. Open an **incognito/private** browser window
2. Navigate to `https://kiali.easysolution.work`
3. Click **Log In With OpenID**
4. You should be redirected to the Keycloak login page
5. Enter credentials (e.g., `viewer@easysolution.work` / `viewer123`)
6. After successful login, you should see the Kiali dashboard

---

## Troubleshooting

### Nginx: Connection Refused or 502 Bad Gateway

```bash
# Check if backend service is running
systemctl status keycloak   # for Keycloak issues
systemctl status vault      # for Vault issues

# Check Nginx config syntax
nginx -t

# Check Nginx logs
tail -20 /var/log/nginx/error.log

# Check TLS certificates exist
ls -la /etc/ssl/easysolution/
```

### Vault: Sealed After Restart

Vault seals itself after every restart. Unseal it:

```bash
export VAULT_ADDR=https://vault.easysolution.work

vault operator unseal <unseal-key-1>
vault operator unseal <unseal-key-2>
```

You need 2 out of 3 unseal keys (threshold).

### Jaeger: 500 Internal Server Error on OAuth2 Callback

Check OAuth2 Proxy logs:

```bash
kubectl logs -n istio-system -l app.kubernetes.io/name=oauth2-proxy-jaeger --tail=50 | grep -v "kube-probe"
```

| Error Message | Cause | Fix |
|---------------|-------|-----|
| `"Invalid client or Invalid client credentials"` | `jaeger-client-secret` in Vault doesn't match Keycloak | Get the correct secret from Keycloak and update Vault (Part 6) |
| `email in id_token (...) isn't verified` | User's email is not verified in Keycloak | Set `emailVerified: true` (Part 5.3) |
| `token exchange failed` | `jaeger-proxy` client misconfigured | Verify it's confidential with correct redirect URIs (Part 5.4) |

### Jaeger: OAuth2 Proxy Pod CrashLoopBackOff

```bash
kubectl logs -n istio-system -l app.kubernetes.io/name=oauth2-proxy-jaeger --previous --tail=20
```

Common cause: Invalid `oauth2-proxy-cookie-secret` (must be a valid base64 string, typically 32 bytes).

### Kiali: "OpenID authentication failed"

Check Kiali logs:

```bash
kubectl logs -n istio-system -l app.kubernetes.io/name=kiali --tail=30 | grep -i "error\|auth"
```

| Error Message | Cause | Fix |
|---------------|-------|-----|
| `request failed (HTTP response status = 401 Unauthorized)` | `kiali` client is confidential in Keycloak | Change to public: `publicClient: true` (Part 5.2) |
| `Token is not valid or is expired: Unauthorized` | Kiali passes OIDC token to K8s API which rejects it | Set `disable_rbac: true` in Kiali values (Part 8) |

### Secrets Not Syncing from Vault to Kubernetes

```bash
# Check VaultStaticSecret status
kubectl get vaultstaticsecret -n istio-system

# Check operator logs
kubectl logs -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator --tail=30

# Force re-sync
kubectl rollout restart deployment -n vault-secrets-operator-system vault-secrets-operator-controller-manager
```

### Complete Reset Script

If everything is broken, run this script on the Keycloak server to reset from scratch:

```bash
#!/bin/bash
set -euo pipefail

KEYCLOAK_API="http://localhost:8080"
ADMIN_PASSWORD="<ADMIN_PASSWORD>"
VAULT_TOKEN="<VAULT_TOKEN>"
VAULT_ADDR="https://vault.easysolution.work"

# 1. Get admin token
TOKEN=$(curl -s -X POST "${KEYCLOAK_API}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=${ADMIN_PASSWORD}" \
  -d "grant_type=password" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# 2. Regenerate jaeger-proxy secret
CLIENT_UUID=$(curl -s "${KEYCLOAK_API}/admin/realms/istio/clients?clientId=jaeger-proxy" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

NEW_SECRET=$(curl -s -X POST "${KEYCLOAK_API}/admin/realms/istio/clients/$CLIENT_UUID/client-secret" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])")

COOKIE_SECRET=$(openssl rand -base64 32 | head -c 32)

# 3. Ensure kiali is public
KIALI_UUID=$(curl -s "${KEYCLOAK_API}/admin/realms/istio/clients?clientId=kiali" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")

curl -s -X PUT "${KEYCLOAK_API}/admin/realms/istio/clients/$KIALI_UUID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"clientId":"kiali","publicClient":true}'

# 4. Set emailVerified for all users
for USER_ID in $(curl -s "${KEYCLOAK_API}/admin/realms/istio/users" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys,json
for u in json.load(sys.stdin):
    if not u.get('emailVerified'):
        print(u['id'])
"); do
  curl -s -X PUT "${KEYCLOAK_API}/admin/realms/istio/users/$USER_ID" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"emailVerified": true}'
done

# 5. Write to Vault
curl -s -X POST "${VAULT_ADDR}/v1/secret/data/istio/keycloak" \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"data\":{\"jaeger-client-secret\":\"$NEW_SECRET\",\"oauth2-proxy-cookie-secret\":\"$COOKIE_SECRET\"}}"

echo ""
echo "=== Reset complete ==="
echo "jaeger-client-secret: $NEW_SECRET"
echo "oauth2-proxy-cookie-secret: $COOKIE_SECRET"
echo ""
echo "Now run on the K8s master:"
echo "  kubectl rollout restart deployment -n vault-secrets-operator-system vault-secrets-operator-controller-manager"
echo "  sleep 30"
echo "  kubectl delete pod -n istio-system -l app.kubernetes.io/name=oauth2-proxy-jaeger"
echo "  kubectl delete pod -n istio-system -l app.kubernetes.io/name=kiali"
```

---

## Appendix: Prometheus Metrics for Vault & Keycloak

Both Vault and Keycloak run on a bare-metal server outside Kubernetes. Since they are not Kubernetes Services, `ServiceMonitor` cannot be used. Instead, Prometheus scrapes them via `additionalScrapeConfigs` with `static_configs`.

### Step 1: Enable Vault Metrics

Edit `/etc/vault.d/vault.hcl` on the bare-metal server. Two changes are needed:

1. Add `telemetry` sub-block inside the `listener` stanza (Vault 1.15+ requires this placement):

```hcl
listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
  telemetry {
    unauthenticated_metrics_access = true
  }
}
```

2. Keep the top-level `telemetry` stanza for retention settings:

```hcl
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname          = true
}
```

`unauthenticated_metrics_access = true` allows Prometheus to scrape without a Vault token. Without this flag, every scrape request would need an `X-Vault-Token` header, which Prometheus does not natively support.

> **Important:** In Vault 1.15+, placing `unauthenticated_metrics_access` in the top-level `telemetry` block causes a warning and has no effect. It must be inside `listener.telemetry`.

Restart Vault (unseal required after restart):

```bash
sudo systemctl restart vault
export VAULT_ADDR=http://127.0.0.1:8200
vault operator unseal <KEY_1>
vault operator unseal <KEY_2>
vault operator unseal <KEY_3>
```

**Verify:**

```bash
curl -sk "https://vault.easysolution.work/v1/sys/metrics?format=prometheus" | head -5
```

### Step 2: Enable Keycloak Metrics

Edit `/etc/systemd/system/keycloak.service` on the bare-metal server:

```ini
ExecStart=/opt/keycloak/bin/kc.sh start --metrics-enabled=true --health-enabled=true
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart keycloak
```

Keycloak exposes metrics on **management port 9000**, not the main port 8080. Add an Nginx proxy location **before** the `location /` block in `/etc/nginx/sites-available/keycloak.conf`:

```nginx
location /metrics {
    proxy_pass         http://127.0.0.1:9000/metrics;
    proxy_set_header   Host $host;
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

**Verify:**

```bash
curl -sk https://keycloak.easysolution.work/metrics | head -5
```

### Step 3: Add Prometheus Scrape Configs

Add the following to `kube-prometheus-stack-values.yaml` under `prometheus.prometheusSpec`:

```yaml
additionalScrapeConfigs:
  - job_name: 'vault'
    scheme: https
    metrics_path: /v1/sys/metrics
    params:
      format: ['prometheus']
    tls_config:
      insecure_skip_verify: true
    static_configs:
      - targets: ['vault.easysolution.work']
        labels:
          instance: vault
  - job_name: 'keycloak'
    scheme: https
    metrics_path: /metrics
    tls_config:
      insecure_skip_verify: true
    static_configs:
      - targets: ['keycloak.easysolution.work']
        labels:
          instance: keycloak
```

**Explanation of fields:**
- `scheme: https` — targets are behind Nginx with TLS
- `tls_config.insecure_skip_verify: true` — Prometheus pod does not have the server's CA certificate, so TLS verification is skipped
- `metrics_path` — Vault uses `/v1/sys/metrics`, Keycloak uses `/metrics`
- `params.format: ['prometheus']` — Vault needs this query parameter to return Prometheus format (default is JSON)
- `static_configs` — since these are not Kubernetes services, targets are specified as static hostnames

After ArgoCD syncs the change, verify targets are UP in Prometheus UI: **Status → Targets → vault / keycloak**.

### Step 4: Verify in Prometheus

```
# Vault — check if unsealed
vault_core_unsealed

# Keycloak — check JVM uptime
base_jvm_uptime_seconds
```

### Key Metrics Available

**Vault:**
- `vault_core_unsealed` — seal status (1 = unsealed)
- `vault_token_count` — active token count
- `vault_secret_kv_count` — KV secret count
- `vault_runtime_alloc_bytes` — memory allocation
- `vault_barrier_get_count` / `vault_barrier_put_count` — storage operations

**Keycloak:**
- `vendor_cache_container_stats_*` — Infinispan cache statistics
- `base_jvm_uptime_seconds` — JVM uptime
- `base_memory_usedHeap_bytes` — heap usage
- `vendor_statistics_*` — session/login statistics
