# Pipeline Injection — Developer Repo → GitHub Actions + Secrets

When a developer writes `repo: https://github.com/user/repo` in BasePlate-Dev, the operator automatically:

1. **Pipeline** — adds a `.github/workflows/build-push.yaml` file to the repo.
2. **Secrets** — adds `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` as GitHub Actions secrets.

## What gets injected

### 1. Workflow file (`.github/workflows/build-push.yaml`)

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

| Secret             | Meaning                | Example value   |
|--------------------|------------------------|-----------------|
| REGISTRY_USERNAME  | Registry login         | admin           |
| REGISTRY_PASSWORD  | Registry password      | EasyDeploy2026  |

Secrets are write-only — GitHub Settings → Secrets and variables → Actions shows only the names, never the values.

## Prerequisite: github-pipeline-secret

The operator needs a `GITHUB_TOKEN` to inject the pipeline. The token comes from `github-pipeline-secret`:

```bash
# One-time — on a new cluster or when rotating the token
GITHUB_TOKEN=ghp_xxx ./scripts/bootstrap-pipeline-secret.sh

# Restart the operator so it picks the secret up as an env var
kubectl -n easy-deploy-system rollout restart deployment easy-deploy-operator
```

**Required `GITHUB_TOKEN` scope:** `repo` (full) or fine-grained: `Contents: Read and write`, `Secrets: Read and write`.

## Verification

```bash
# 1. Secret present?
kubectl -n easy-deploy-system get secret github-pipeline-secret

# 2. Operator logs — was injection successful?
kubectl -n easy-deploy-system logs deployment/easy-deploy-operator --tail=50 | grep -i pipeline

# Success: "pipeline injected" repo=...
# Failure: "pipeline injection failed" — GITHUB_TOKEN missing or insufficient permissions

# 3. Workflow file in the tenant repo?
# GitHub → repo → Code → .github/workflows/

# 4. GitHub Actions Secrets
# Repo → Settings → Secrets and variables → Actions
# REGISTRY_USERNAME, REGISTRY_PASSWORD should be listed
```

## Re-running a failed injection

If the BirService is incorrectly marked with `deploy.easydeploy.io/pipeline-injected: "true"`, or you've just fixed the token:

```bash
# Remove the annotation — the operator will retry injection on next reconcile
kubectl -n loadtest annotate birservice hello-csharp deploy.easydeploy.io/pipeline-injected-
```
