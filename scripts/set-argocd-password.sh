#!/bin/bash
# ArgoCD static admin password: EasyDeploy2026
# İstifadə: ./set-argocd-password.sh
#          ./set-argocd-password.sh "MyPassword"

PASSWORD="${1:-EasyDeploy2026}"

# Pre-generated bcrypt hash for EasyDeploy2026 (zero deps when using default)
HASH_EASYDEPLOY='$2b$12$.ozrfe.uj.j29CDBY/lw/eMoFsA40jLYbX/FoJDEBG4IgNZh2gomW'

get_hash() {
  if command -v argocd &> /dev/null; then
    argocd account bcrypt --password "$1"
  elif command -v docker &> /dev/null; then
    docker run --rm argoproj/argocd:latest argocd account bcrypt --password "$1"
  elif command -v python3 &> /dev/null; then
    python3 -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())" "$1" 2>/dev/null
  elif command -v python &> /dev/null; then
    python -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())" "$1" 2>/dev/null
  else
    return 1
  fi
}

# Bcrypt hash - default parol üçün hazır hash, custom üçün avtomatik generate
if [ "$PASSWORD" = "EasyDeploy2026" ]; then
  HASH="$HASH_EASYDEPLOY"
else
  HASH=$(get_hash "$PASSWORD")
  if [ -z "$HASH" ]; then
    # python var amma bcrypt yoxdursa - pip install et və təkrar yoxla
    (command -v pip3 &>/dev/null && pip3 install bcrypt -q 2>/dev/null) || (command -v pip &>/dev/null && pip install bcrypt -q 2>/dev/null)
    HASH=$(get_hash "$PASSWORD")
  fi
  if [ -z "$HASH" ] || [ "${#HASH}" -lt 50 ]; then
    echo "Bcrypt generate edilə bilmədi. argocd, docker və ya python lazımdır."
    exit 1
  fi
fi

MTime=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S)
kubectl -n argocd patch secret argocd-secret --type merge -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$MTime\"}}"

# ArgoCD uses argocd-initial-admin-secret if it exists - our custom password is ignored!
# Delete it so ArgoCD falls back to admin.password in argocd-secret.
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found=true

# Restart server to pick up changes
kubectl -n argocd rollout restart deployment argocd-server

echo "Password updated: $PASSWORD"
echo "Wait ~30s for argocd-server rollout, then login at https://argocd.easysolution.work"
