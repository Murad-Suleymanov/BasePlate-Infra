#!/bin/bash
# ArgoCD static admin password: EasyDeploy2026
# İstifadə: ./set-argocd-password.sh
#          ./set-argocd-password.sh "MyPassword"

PASSWORD="${1:-EasyDeploy2026}"

# Bcrypt hash - argocd CLI və ya docker
if command -v argocd &> /dev/null; then
  HASH=$(argocd account bcrypt --password "$PASSWORD")
elif command -v docker &> /dev/null; then
  HASH=$(docker run --rm argoproj/argocd:latest argocd account bcrypt --password "$PASSWORD")
else
  echo "argocd və ya docker lazımdır."
  echo "Və ya bcrypt-generator.com-dan hash alıb patch edin."
  exit 1
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
