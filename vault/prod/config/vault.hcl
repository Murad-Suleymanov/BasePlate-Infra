storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-prod-1"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

api_addr     = "https://vault.easysolution.work"
cluster_addr = "https://vault.easysolution.work:8201"

# TLS is terminated by Nginx reverse proxy on port 443.
# Vault listens locally on 8200 (plain HTTP) and is proxied via Nginx.

ui = true

disable_mlock = true

max_lease_ttl     = "768h"
default_lease_ttl = "768h"
