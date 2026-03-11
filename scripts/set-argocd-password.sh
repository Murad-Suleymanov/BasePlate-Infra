#!/bin/bash
# ArgoCD static admin password: EasyDeploy2026!
# İstifadə: ./set-argocd-password.sh

PASSWORD="${1:-EasyDeploy2026!}"

# Bcrypt hash generasiya - argocd CLI və ya docker
if command -v argocd &> /dev/null; then
  HASH=$(argocd account bcrypt --password "$PASSWORD")
elif command -v docker &> /dev/null; then
  HASH=$(docker run --rm argoproj/argocd:latest argocd account bcrypt --password "$PASSWORD")
else
  echo "argocd CLI və ya docker lazımdır. Manual:"
  echo "  argocd account bcrypt --password \"$PASSWORD\""
  echo "Sonra: kubectl -n argocd patch secret argocd-secret --type merge -p '{\"stringData\":{\"admin.password\":\"HASH_BURAYA\",\"admin.passwordMtime\":\"'$(date +%FT%T%Z)'\"}}'"
  exit 1
fi

kubectl -n argocd patch secret argocd-secret --type merge -p "{\"stringData\":{\"admin.password\":\"$HASH\",\"admin.passwordMtime\":\"$(date +%FT%T%Z)\"}}"
echo "Password yeniləndi: $PASSWORD"
