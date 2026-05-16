# System components — metrics and dashboard requirements

For every system component we run:
1. **Metric** — a `/metrics` (or equivalent) endpoint Prometheus can scrape
2. **ServiceMonitor / PodMonitor** — the resource that tells Prometheus "scrape this target"
3. **Grafana dashboard** — visualization

---

## Platform components — current status

| Component | Namespace | Metrics endpoint | ServiceMonitor | Dashboard |
|-----------|-----------|------------------|----------------|-----------|
| **Easy-Deploy Operator** | easy-deploy-system | :8080/metrics | ✅ PodMonitor | ❌ |
| **Registry** | registry | :5000/metrics (n/a) | ❌ | ❌ |
| **Registry-UI** | registry | :80 (no metrics) | ❌ | ❌ |
| **NGINX Gateway Fabric** | nginx-gateway | exposed by chart | ✅ kube-prom | ✅ NGINX |
| **ArgoCD** | argocd | :8082/metrics | ✅ kube-prom | ✅ ArgoCD |
| **Prometheus** | monitoring | :9090/metrics | ✅ self | ✅ |
| **Grafana** | monitoring | :3000/metrics | ✅ kube-prom | — |
| **Alertmanager** | monitoring | :9093/metrics | ✅ kube-prom | — |
| **Calico Felix** | kube-system | :9091/metrics | ✅ ours | ❌ |
| **BirService apps** (hello-csharp, etc.) | loadtest, etc. | :8080/metrics | ✅ operator | ✅ BirService |
| **Istiod** | istio-system | :15014/metrics | ✅ ours | ❌ |
| **Envoy sidecars** | (all injected) | :15090/stats/prometheus | ✅ ours (PodMonitor) | ❌ |
| **Jaeger** | istio-system | :14269/metrics | ✅ ours | ❌ |
| **Kiali** | istio-system | :9090/metrics | ✅ ours | ❌ |
| **ExternalDNS** | external-dns | :7979/metrics | ✅ chart | ❌ |
| **cert-manager** | cert-manager | :9402/metrics | ✅ chart | ❌ |
| **Vault** | external (bare-metal) | :8200/v1/sys/metrics | ✅ additionalScrapeConfigs | ❌ |
| **Keycloak** | external (bare-metal) | :9000/metrics (via Nginx) | ✅ additionalScrapeConfigs | ❌ |

---

## Principles

1. **Metrics endpoint** — every component must expose a `/metrics` (Prometheus format) or health endpoint.
2. **ServiceMonitor** — when Prometheus is in-cluster, every component should have a ServiceMonitor (or PodMonitor).
3. **Dashboard** — at minimum a generic "up" panel plus the component's primary metrics; critical components get their own dashboard.

---

## What still needs adding

### 1. Easy-Deploy Operator ✅
- PodMonitor: `monitoring/operator-servicemonitor.yaml` — added
- Dashboard: controller reconcile rate, error count, workqueue depth (optional)

### 2. Registry
- The Registry image does not support metrics natively — alternative: a sidecar exporter, or a health-check-based probe.
- Simple "up" check: TCP probe against the Registry service.

### 3. Calico
- ServiceMonitor ✅ (our `calico-servicemonitor.yaml`)
- Dashboard: Felix metrics panel (ops/sec, policy count, etc.)

### 4. ExternalDNS
- ServiceMonitor: ✅ chart-supported, `serviceMonitor.enabled: true` is set.

### 5. cert-manager
- ServiceMonitor: ✅ chart-supported, `prometheus.servicemonitor.enabled: true` is set.

### 6. Registry / Registry-UI
- Docker Registry v2 does not expose `/metrics` by default (debug mode required).
- Registry-UI (joxit) has no metrics endpoint.
- Alternative: "up" check via TCP/HTTP probe.

### 7. Vault (external)
- Scraped via Prometheus `additionalScrapeConfigs` (ServiceMonitor not usable — Vault is outside Kubernetes).
- Metrics endpoint: `https://vault.easysolution.work/v1/sys/metrics?format=prometheus`
- Auth: not required when `unauthenticated_metrics_access = true`.
- Enable in `vault.hcl`:
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
- **Note:** in Vault 1.15+ `unauthenticated_metrics_access` must live inside the `listener.telemetry` block (it is not supported at the top-level `telemetry` block).
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
- Scraped via Prometheus `additionalScrapeConfigs` (ServiceMonitor not usable — Keycloak is outside Kubernetes).
- Metrics endpoint: `https://keycloak.easysolution.work/metrics` (Nginx → localhost:9000).
- Auth: not required.
- Enable: `kc.sh start --metrics-enabled=true --health-enabled=true`.
- Nginx must expose a `/metrics` location proxying to port 9000.
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

### Why `additionalScrapeConfigs`?
Vault and Keycloak run on bare-metal servers outside the Kubernetes cluster. `ServiceMonitor` only works for in-cluster Kubernetes Services. For external targets we use Prometheus' `static_configs` + `additionalScrapeConfigs` mechanism. `insecure_skip_verify: true` is needed because the Prometheus pod cannot validate the server certificate.
