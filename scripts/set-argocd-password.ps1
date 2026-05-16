# ArgoCD static admin password: EasyDeploy2026
# Usage: .\set-argocd-password.ps1
#        .\set-argocd-password.ps1 "CustomPassword"

param(
    [string]$Password = "EasyDeploy2026",
    [string]$Environment = $(if ($env:ENV) { $env:ENV } else { "dev" })
)

$ArgoHost = if ($Environment -eq "prod") { "argocd.easysolution.work" } else { "argocd-$Environment.easysolution.work" }

# Pre-generated bcrypt hash for EasyDeploy2026 (zero deps when using default)
$HashEasyDeploy = '$2b$12$.ozrfe.uj.j29CDBY/lw/eMoFsA40jLYbX/FoJDEBG4IgNZh2gomW'

function Get-BcryptHash {
    param([string]$Pwd)
    if (Get-Command argocd -ErrorAction SilentlyContinue) {
        return argocd account bcrypt --password $Pwd
    }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        return docker run --rm argoproj/argocd:latest argocd account bcrypt --password $Pwd
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        return python -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())" $Pwd 2>$null
    }
    if (Get-Command python3 -ErrorAction SilentlyContinue) {
        return python3 -c "import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt()).decode())" $Pwd 2>$null
    }
    return $null
}

$Hash = if ($Password -eq "EasyDeploy2026") { $HashEasyDeploy } else { Get-BcryptHash $Password }
if (-not $Hash -and $Password -ne "EasyDeploy2026") {
    # Try pip install bcrypt and retry
    pip install bcrypt -q 2>$null; pip3 install bcrypt -q 2>$null
    $Hash = Get-BcryptHash $Password
}
if (-not $Hash -or $Hash.Length -lt 50) {
    Write-Host "Could not generate bcrypt hash. Install argocd, docker, or python."
    exit 1
}

$Mtime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$PatchJson = "{`"stringData`":{`"admin.password`":`"$Hash`",`"admin.passwordMtime`":`"$Mtime`"}}"
kubectl -n argocd patch secret argocd-secret --type merge -p $PatchJson

# ArgoCD uses argocd-initial-admin-secret if it exists - our custom password is ignored!
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found=true

# Restart server to pick up changes
kubectl -n argocd rollout restart deployment argocd-server

Write-Host "Password updated: $Password"
Write-Host "Wait ~30s for argocd-server rollout, then login at https://$ArgoHost"
