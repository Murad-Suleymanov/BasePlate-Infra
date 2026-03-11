# Pipeline şablonları

Repolara əlavə edə biləcəyiniz CI/CD workflow-ları.

## GitHub Actions — Build & Push

Hər push-da image yaradır və `registry.easysolution.work`-ə push edir.

### 1. Workflow faylını əlavə et

Reponun kökünə `.github/workflows/build-push.yaml` yarat və `github-actions-build-push.yaml` məzmununu kopyala.

### 2. Registry credentials (Secret)

GitHub repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret             | Dəyər                          |
|--------------------|---------------------------------|
| `REGISTRY_USERNAME`| Registry istifadəçi adı         |
| `REGISTRY_PASSWORD`| Registry parolu və ya token     |

> Registry-də auth yoxdursa: `REGISTRY_USERNAME` = `""`, `REGISTRY_PASSWORD` = `""` (boş) — bəzi konfiqurasiyalarda işləyə bilər. Güvənli istifadə üçün auth tövsiyə olunur.

### 3. Dockerfile

Repo kökündə `Dockerfile` olmalıdır. Başqa path üçün `context` və `file` dəyişdirin:

```yaml
with:
  context: ./backend    # məs: alt qovluq
  file: ./backend/Dockerfile
```

### 4. Image adları

- `latest` — hər push-da yenilənir  
- `<short_sha>` — commit hash (məs: `abc1234`), versiya kimi işləyir  

BasePlate-Dev-də `todo-api/dev.yaml` və s. `image: registry.easysolution.work/todo-api:latest` istifadə edə bilər və ya `:abc1234` ilə sabit versiya.

### 5. Fərqli image adı (monorepo)

Repo adı service adından fərqlidirsə (məs: `my-monorepo` → `todo-api`), workflow-da `image_name` dəyişdirin:

```yaml
- name: Set image name
  id: vars
  run: |
    echo "image_name=todo-api" >> $GITHUB_OUTPUT
    echo "short_sha=${GITHUB_SHA::7}" >> $GITHUB_OUTPUT
```
