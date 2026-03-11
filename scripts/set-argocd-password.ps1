# ArgoCD static admin password: EasyDeploy2026!
# Usage: .\set-argocd-password.ps1
#        .\set-argocd-password.ps1 "CustomPassword"

param([string]$Password = "EasyDeploy2026!")

$Hash = $null
if (Get-Command argocd -ErrorAction SilentlyContinue) {
    $Hash = argocd account bcrypt --password $Password
} elseif (Get-Command docker -ErrorAction SilentlyContinue) {
    $Hash = docker run --rm argoproj/argocd:latest argocd account bcrypt --password $Password
}

if (-not $Hash) {
    Write-Host "argocd CLI or docker required. Run manually:"
    Write-Host "  argocd account bcrypt --password `"$Password`""
    Write-Host "Then patch: kubectl -n argocd patch secret argocd-secret --type merge -p '{...}'"
    exit 1
}

$Mtime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$PatchJson = "{`"stringData`":{`"admin.password`":`"$Hash`",`"admin.passwordMtime`":`"$Mtime`"}}"
kubectl -n argocd patch secret argocd-secret --type merge -p $PatchJson
Write-Host "Password updated: $Password"
