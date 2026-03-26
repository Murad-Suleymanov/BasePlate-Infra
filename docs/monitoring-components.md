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
