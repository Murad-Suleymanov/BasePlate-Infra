# Pipeline templates

CI/CD workflows you can add to your repositories.

## GitHub Actions — Build & Push

Builds an image on every push and pushes it to `registry.easysolution.work`.

### 1. Add the workflow file

Create `.github/workflows/build-push.yaml` at the root of your repo and copy the contents of `github-actions-build-push.yaml`.

### 2. Registry credentials (Secret)

GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret             | Value                            |
|--------------------|----------------------------------|
| `REGISTRY_USERNAME`| Registry username                |
| `REGISTRY_PASSWORD`| Registry password or token       |

> If the registry has auth disabled: leave both empty (`""`). It may work in some configurations, but auth is recommended for any real use.

### 3. Dockerfile

The repo must have a `Dockerfile` at the root. For a different path, override `context` and `file`:

```yaml
with:
  context: ./backend    # e.g. subdirectory
  file: ./backend/Dockerfile
```

### 4. Image tags

- `latest` — updated on every push
- `<short_sha>` — commit hash (e.g. `abc1234`), serves as a version tag

In BasePlate-Dev, `todo-api/dev.yaml` (and similar) can reference `image: registry.easysolution.work/todo-api:latest`, or pin a specific build with `:abc1234`.

### 5. Different image name (monorepo)

If the repo name differs from the service name (e.g. `my-monorepo` → `todo-api`), override `image_name` in the workflow:

```yaml
- name: Set image name
  id: vars
  run: |
    echo "image_name=todo-api" >> $GITHUB_OUTPUT
    echo "short_sha=${GITHUB_SHA::7}" >> $GITHUB_OUTPUT
```
