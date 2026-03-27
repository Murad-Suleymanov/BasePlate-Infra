# Sistem komponentləri — metrik və dashboard tələbləri

Hər run olunan sistem komponenti üçün:
1. **Metrik** — Prometheus-un scrape edə biləcəyi `/metrics` və ya ekvivalent endpoint
2. **ServiceMonitor/PodMonitor** — Prometheus-a "bu target-i scrape et" deyən resource
3. **Grafana dashboard** — vizualizasiya

---

## Platform komponentləri — cari vəziyyət

| Komponent | Namespace | Metrik endpoint | ServiceMonitor | Dashboard |
|-----------|-----------|-----------------|----------------|-----------|
| **Easy-Deploy Operator** | easy-deploy-system | :8080/metrics | ✅ PodMonitor | ❌ |
| **Registry** | registry | :5000/metrics (yoxdur) | ❌ | ❌ |
| **Registry-UI** | registry | :80 (metrics yoxdur) | ❌ | ❌ |
| **NGINX Gateway Fabric** | nginx-gateway | var (chart) | ✅ kube-prom | ✅ NGINX |
| **ArgoCD** | argocd | :8082/metrics | ✅ kube-prom | ✅ ArgoCD |
| **Prometheus** | monitoring | :9090/metrics | ✅ özü | ✅ |
| **Grafana** | monitoring | :3000/metrics | ✅ kube-prom | — |
| **Alertmanager** | monitoring | :9093/metrics | ✅ kube-prom | — |
| **Calico Felix** | kube-system | :9091/metrics | ✅ bizim | ❌ |
| **BirService apps** (hello-csharp və s.) | loadtest və s. | :8080/metrics | ✅ operator | ✅ BirService |
| **Istiod** | istio-system | :15014/metrics | ✅ bizim | ❌ |
| **Envoy sidecars** | (all injected) | :15090/stats/prometheus | ✅ bizim (PodMonitor) | ❌ |
| **Jaeger** | istio-system | :14269/metrics | ✅ bizim | ❌ |
| **Kiali** | istio-system | :9090/metrics | ✅ bizim | ❌ |
| **ExternalDNS** | external-dns | :7979/metrics | ✅ chart | ❌ |
| **cert-manager** | cert-manager | :9402/metrics | ✅ chart | ❌ |
| **Vault** | external (bare-metal) | :8200/v1/sys/metrics | ✅ additionalScrapeConfigs | ❌ |
| **Keycloak** | external (bare-metal) | :9000/metrics (via Nginx) | ✅ additionalScrapeConfigs | ❌ |

---

## Nəzərdə tutulan prinsip

1. **Metrik endpoint** — komponent `/metrics` (Prometheus format) və ya health endpoint expose etməlidir
2. **ServiceMonitor** — Prometheus cluster-da olduqda, hər komponent üçün ServiceMonitor (və ya PodMonitor) olmalıdır
3. **Dashboard** — ən azı ümumi "up" və əsas metrik paneli; kritik komponentlər üçün ayrıca dashboard

---

## Əlavə edilməli

### 1. Easy-Deploy Operator ✅
- PodMonitor: `monitoring/operator-servicemonitor.yaml` — əlavə olundu
- Dashboard: controller reconcile rate, error count, workqueue depth (opsional)

### 2. Registry
- Registry image metrics dəstəkləmir — alternativ: sidecar exporter və ya health check əsaslı yoxlama
- Sadə "up" check: Registry service-ə TCP probe

### 3. Calico
- ServiceMonitor ✅ (bizim calico-servicemonitor.yaml)
- Dashboard: Felix metrik paneli (ops/sec, policy count və s.)

### 4. ExternalDNS
- ServiceMonitor: ✅ chart dəstəkləyir, `serviceMonitor.enabled: true` aktiv edildi

### 5. cert-manager
- ServiceMonitor: ✅ chart dəstəkləyir, `prometheus.servicemonitor.enabled: true` aktiv edildi

### 6. Registry / Registry-UI
- Docker Registry v2 default-da `/metrics` expose etmir (debug mode lazımdır)
- Registry-UI (joxit) metrics endpoint-i yoxdur
- Alternativ: TCP/HTTP probe ilə "up" yoxlaması

### 7. Vault (external)
- Prometheus `additionalScrapeConfigs` ilə scrape olunur (ServiceMonitor istifadə oluna bilməz — Kubernetes xaricindədir)
- Metrics endpoint: `https://vault.easysolution.work/v1/sys/metrics?format=prometheus`
- Auth: `unauthenticated_metrics_access = true` ilə token tələb etmir
- Aktivləşdirmə (`vault.hcl`):
  ```hcl
  listener "tcp" {
    address     = "127.0.0.1:8200"
    tls_disable = true
    telemetry {
      unauthenticated_metrics_access = true
    }
  }

  telemetry {
    prometheus_retention_time = "30s"
    disable_hostname          = true
  }
  ```
- **Qeyd:** Vault 1.15+ versiyalarda `unauthenticated_metrics_access` `listener.telemetry` blokunda olmalıdır (top-level `telemetry`-də dəstəklənmir)
- Prometheus scrape config (`kube-prometheus-stack-values.yaml`):
  ```yaml
  additionalScrapeConfigs:
    - job_name: 'vault'
      scheme: https
      metrics_path: /v1/sys/metrics
      params:
        format: ['prometheus']
      tls_config:
        insecure_skip_verify: true
      static_configs:
        - targets: ['vault.easysolution.work']
  ```

### 8. Keycloak (external)
- Prometheus `additionalScrapeConfigs` ilə scrape olunur (ServiceMonitor istifadə oluna bilməz — Kubernetes xaricindədir)
- Metrics endpoint: `https://keycloak.easysolution.work/metrics` (Nginx → localhost:9000)
- Auth: lazım deyil
- Aktivləşdirmə: `kc.sh start --metrics-enabled=true --health-enabled=true`
- Nginx-də `/metrics` location əlavə olunmalıdır (port 9000-ə proxy)
- Prometheus scrape config (`kube-prometheus-stack-values.yaml`):
  ```yaml
  additionalScrapeConfigs:
    - job_name: 'keycloak'
      scheme: https
      metrics_path: /metrics
      tls_config:
        insecure_skip_verify: true
      static_configs:
        - targets: ['keycloak.easysolution.work']
  ```

### Niyə `additionalScrapeConfigs`?
Vault və Keycloak Kubernetes klasterinin xaricində, bare-metal serverdə işləyir. `ServiceMonitor`
yalnız klaster daxilindəki Kubernetes Service-lər üçün işləyir. External target-lər üçün
Prometheus-un `static_configs` + `additionalScrapeConfigs` mexanizmi istifadə olunur.
`insecure_skip_verify: true` Prometheus pod-unun server sertifikatını verify edə bilmədiyinə görə lazımdır.
