storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-prod-1"
}

listener "tcp" {
  address       = "0.0.0.0:443"
  tls_cert_file = "/etc/vault.d/tls/fullchain.pem"
  tls_key_file  = "/etc/vault.d/tls/privkey.pem"
}

api_addr     = "https://vault.easysolution.work"
cluster_addr = "https://vault.easysolution.work:8201"

ui = true

disable_mlock = true

max_lease_ttl     = "768h"
default_lease_ttl = "768h"
