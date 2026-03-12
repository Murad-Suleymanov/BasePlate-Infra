# Pipeline Injection — Developer Repo → GitHub Actions + Secrets

Developer BasePlate-Dev-da `repo: https://github.com/user/repo` yazanda, operator avtomatik:

1. **Pipeline** — `.github/workflows/build-push.yaml` faylını repo-ya əlavə edir
2. **Secrets** — `REGISTRY_USERNAME` və `REGISTRY_PASSWORD` GitHub Actions secret kimi əlavə edir

## Nə inject olunur

### 1. Workflow faylı (`.github/workflows/build-push.yaml`)

```yaml
name: Build & Push to Easy Deploy Registry
on:
  push:
    branches: [main, master]

jobs:
  build-and-push:
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: registry.easysolution.work
          username: ${{ secrets.REGISTRY_USERNAME }}
          password: ${{ secrets.REGISTRY_PASSWORD }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: registry.easysolution.work/hello-csharp:${{ github.sha }}
      - run: curl -X POST webhook.../webhook/build-complete -d '{"service":"...","namespace":"..."}'
```

### 2. GitHub Actions Secrets

| Secret             | Məna                    | Dəyər (nümunə) |
|--------------------|------------------------|-----------------|
| REGISTRY_USERNAME  | Registry login         | admin           |
| REGISTRY_PASSWORD  | Registry şifrə         | EasyDeploy2026  |

Secrets görünməz — GitHub Settings → Secrets and variables → Actions-da yalnız adları görünür.

## Prerequisite: github-pipeline-secret

Operator pipeline inject etmək üçün `GITHUB_TOKEN` lazımdır. Token `github-pipeline-secret`-dən gəlir:

```bash
# Bir dəfə — yeni cluster və ya token yeniləmək üçün
GITHUB_TOKEN=ghp_xxx ./scripts/bootstrap-pipeline-secret.sh

# Operator restart — secret env olaraq yüklənsin
kubectl -n easy-deploy-system rollout restart deployment easy-deploy-operator
```

**GITHUB_TOKEN scope:** `repo` (full) və ya fine-grained: `Contents: Read and write`, `Secrets: Read and write`

## Yoxlama

```bash
# 1. Secret var?
kubectl -n easy-deploy-system get secret github-pipeline-secret

# 2. Operator logs — injection uğurlu?
kubectl -n easy-deploy-system logs deployment/easy-deploy-operator --tail=50 | grep -i pipeline

# Uğurlu: "pipeline injected" repo=...
# Uğursuz: "pipeline injection failed" — GITHUB_TOKEN yoxdur və ya yetki azdır

# 3. Repoda .github/workflows/build-push.yaml var?
# GitHub → repo → Code → .github/workflows/

# 4. GitHub Actions Secrets
# Repo → Settings → Secrets and variables → Actions
# REGISTRY_USERNAME, REGISTRY_PASSWORD görünməlidir
```

## Injection uğursuzdursa — yenidən cəhd

BirService-də `deploy.easydeploy.io/pipeline-injected: "true"` yanlış qoyulubsa və ya token düzəldildikdən sonra:

```bash
# Annotation sil — operator yenidən inject cəhd edəcək
kubectl -n loadtest annotate birservice hello-csharp deploy.easydeploy.io/pipeline-injected-
```
