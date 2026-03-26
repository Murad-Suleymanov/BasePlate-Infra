# Istio Service Mesh Setup

Complete guide for the Istio service mesh deployment, including mTLS, distributed tracing with Jaeger, service mesh observability with Kiali, and external access via NGINX Gateway Fabric.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Component Versions](#component-versions)
- [Part 1: Istio Base (CRDs)](#part-1-istio-base-crds)
- [Part 2: Istiod (Control Plane)](#part-2-istiod-control-plane)
- [Part 3: Istio Config (Mesh Policies)](#part-3-istio-config-mesh-policies)
- [Part 4: Jaeger (Distributed Tracing)](#part-4-jaeger-distributed-tracing)
- [Part 5: Kiali (Service Mesh Dashboard)](#part-5-kiali-service-mesh-dashboard)
- [Part 6: Sidecar Injection](#part-6-sidecar-injection)
- [Part 7: External Access via NGINX Gateway](#part-7-external-access-via-nginx-gateway)
- [Part 8: Environment Differences (Prod vs Dev)](#part-8-environment-differences-prod-vs-dev)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                               │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ istio-system namespace                                          │    │
│  │                                                                 │    │
│  │  ┌─────────┐  ┌─────────────┐  ┌───────┐  ┌──────────────┐    │    │
│  │  │ istiod  │  │   Jaeger     │  │ Kiali │  │ OAuth2 Proxy │    │    │
│  │  │ (pilot) │  │ (collector + │  │       │  │ (for Jaeger) │    │    │
│  │  │         │  │    query)    │  │       │  │              │    │    │
│  │  └─────────┘  └─────────────┘  └───────┘  └──────────────┘    │    │
│  │                                                                 │    │
│  │  PeerAuthentication: PERMISSIVE (mesh-wide default)             │    │
│  │  Telemetry: zipkin → jaeger-collector:9411                      │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ easy-deploy-system namespace (sidecar injected)                 │    │
│  │                                                                 │    │
│  │  PeerAuthentication: STRICT (mTLS enforced)                     │    │
│  │                                                                 │    │
│  │  ┌──────────────────┐    ┌──────────────────┐                   │    │
│  │  │ App Pod          │    │ App Pod          │                   │    │
│  │  │ ┌──────────────┐ │    │ ┌──────────────┐ │                   │    │
│  │  │ │ App Container│ │◄──►│ │ App Container│ │  ◄── mTLS         │    │
│  │  │ ├──────────────┤ │    │ ├──────────────┤ │                   │    │
│  │  │ │ Envoy Sidecar│ │    │ │ Envoy Sidecar│ │                   │    │
│  │  │ └──────────────┘ │    │ └──────────────┘ │                   │    │
│  │  └──────────────────┘    └──────────────────┘                   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  ┌─────────────────────────┐                                           │
│  │ nginx-gateway namespace  │                                           │
│  │  NGINX Gateway Fabric    │◄── jaeger.easysolution.work              │
│  │  (main-gateway)          │◄── kiali.easysolution.work               │
│  └─────────────────────────┘                                           │
└─────────────────────────────────────────────────────────────────────────┘
```

All Istio components are deployed to the `istio-system` namespace via ArgoCD. Traffic between services in injected namespaces is encrypted with mutual TLS (mTLS). Distributed traces are collected by Jaeger and visualized in the Kiali dashboard.

External access to Jaeger and Kiali is provided through NGINX Gateway Fabric using Kubernetes Gateway API `HTTPRoute` resources — **not** Istio `Gateway`/`VirtualService`.

---

## Component Versions

| Component | Chart | Version | Source |
|-----------|-------|---------|--------|
| Istio Base (CRDs) | `base` | 1.29.1 | `istio-release.storage.googleapis.com/charts` |
| Istiod (Control Plane) | `istiod` | 1.29.1 | `istio-release.storage.googleapis.com/charts` |
| Istio Config | `istio-config` | 1.0.0 | Local chart (`charts/istio-config`) |
| Kiali | `kiali-server` | 2.21.0 | `kiali.org/helm-charts` |
| Jaeger | `jaeger` | 4.6.0 | `jaegertracing.github.io/helm-charts` |

All components are managed as ArgoCD Applications defined in `charts/infra-applications/values.yaml`.

---

## Part 1: Istio Base (CRDs)

Istio Base installs the Custom Resource Definitions (CRDs) required by Istio: `PeerAuthentication`, `Telemetry`, `VirtualService`, `DestinationRule`, `Gateway`, etc.

### Helm Values

```yaml
# prod/istio-base/values/istio-base-values.yaml
defaultRevision: default
```

`defaultRevision: default` sets the default revision tag for the Istio control plane, used for canary upgrades.

### ArgoCD Configuration

```yaml
istio-base:
  enabled: true
  destinationNamespace: istio-system
  source:
    repoURL: https://istio-release.storage.googleapis.com/charts
    chart: base
    targetRevision: "1.29.1"
    helm:
      releaseName: istio-base
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jqPathExpressions:
        - .webhooks[]?.failurePolicy
```

> **Note:** `ServerSideApply=true` and `RespectIgnoreDifferences` are required because Istio's webhook configurations are dynamically modified by istiod after deployment. Without these settings, ArgoCD would continuously report the application as OutOfSync.

---

## Part 2: Istiod (Control Plane)

Istiod is the Istio control plane. It manages the Envoy sidecar proxies, handles certificate rotation for mTLS, and configures traffic routing.

### Helm Values (Production)

```yaml
# prod/istiod/values/istiod-values.yaml
pilot:
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi
  traceSampling: 10.0

meshConfig:
  accessLogFile: /dev/stdout
  enableTracing: true
  defaultConfig:
    tracing:
      zipkin:
        address: jaeger-collector.istio-system:9411
      sampling: 10.0
    holdApplicationUntilProxyStarts: true

global:
  proxy:
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
```

### Key Settings Explained

| Setting | Value | Description |
|---------|-------|-------------|
| `meshConfig.accessLogFile` | `/dev/stdout` | Envoy proxies log all access to stdout (visible via `kubectl logs`) |
| `meshConfig.enableTracing` | `true` | Enables distributed tracing across the mesh |
| `meshConfig.defaultConfig.tracing.zipkin.address` | `jaeger-collector.istio-system:9411` | Envoy sidecars send traces to Jaeger via the Zipkin protocol |
| `meshConfig.defaultConfig.tracing.sampling` | `10.0` (prod) / `100.0` (dev) | Percentage of requests that generate traces |
| `meshConfig.defaultConfig.holdApplicationUntilProxyStarts` | `true` | Application containers wait for the Envoy sidecar to be ready before starting, preventing connection errors during pod startup |
| `global.proxy.resources` | (see above) | Resource limits for every Envoy sidecar container injected into application pods |

### ArgoCD Configuration

```yaml
istiod:
  enabled: true
  destinationNamespace: istio-system
  source:
    repoURL: https://istio-release.storage.googleapis.com/charts
    chart: istiod
    targetRevision: "1.29.1"
    helm:
      releaseName: istiod
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: admissionregistration.k8s.io
      kind: MutatingWebhookConfiguration
      jqPathExpressions:
        - .webhooks[]?.failurePolicy
    - group: admissionregistration.k8s.io
      kind: ValidatingWebhookConfiguration
      jqPathExpressions:
        - .webhooks[]?.failurePolicy
```

---

## Part 3: Istio Config (Mesh Policies)

The `istio-config` chart is a **local Helm chart** (`charts/istio-config/`) that deploys mesh-wide policies, telemetry configuration, HTTP routes, and the OAuth2 Proxy for Jaeger.

### 3.1 PeerAuthentication (mTLS)

File: `charts/istio-config/templates/peer-authentication.yaml`

```yaml
# Mesh-wide default: PERMISSIVE
# Accepts both plaintext and mTLS connections to istio-system
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: PERMISSIVE
---
# Per-namespace: STRICT
# Only mTLS connections allowed in injected namespaces
{{- range .Values.injectedNamespaces }}
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: {{ . }}
spec:
  mtls:
    mode: {{ $.Values.meshConfig.mtlsMode }}
---
{{- end }}
```

**How it works:**
- The `istio-system` namespace uses **PERMISSIVE** mode, allowing both plaintext and mTLS. This is necessary because Jaeger, Kiali, Prometheus, and other observability tools send plaintext traffic to services in `istio-system`.
- Application namespaces listed in `injectedNamespaces` use **STRICT** mode, requiring all traffic to be encrypted with mTLS.

### 3.2 Telemetry (Distributed Tracing)

File: `charts/istio-config/templates/telemetry.yaml`

```yaml
{{- if .Values.tracing.enabled }}
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  tracing:
    - providers:
        - name: zipkin
      randomSamplingPercentage: {{ .Values.tracing.samplingRate }}
{{- end }}
```

This resource configures mesh-wide tracing using the `zipkin` provider (Jaeger is Zipkin-compatible). The `randomSamplingPercentage` controls what percentage of requests generate traces:
- **Production:** 10% (`samplingRate: 10`)
- **Development:** 100% (`samplingRate: 100`)

### 3.3 OAuth2 Proxy for Jaeger

File: `charts/istio-config/templates/oauth2-proxy.yaml`

Deploys an OAuth2 Proxy (v7.7.1) in front of Jaeger to require Keycloak OIDC authentication. See [keycloak-oidc-setup.md](keycloak-oidc-setup.md) for the complete Keycloak integration guide.

### 3.4 HTTPRoutes (Jaeger & Kiali)

Files:
- `charts/istio-config/templates/jaeger-route.yaml`
- `charts/istio-config/templates/kiali-route.yaml`

These create Kubernetes Gateway API `HTTPRoute` resources that attach to the shared NGINX Gateway (`main-gateway` in `nginx-gateway` namespace):

| Route | Hostname | Backend |
|-------|----------|---------|
| `jaeger-route` | `jaeger.easysolution.work` | `oauth2-proxy-jaeger:4180` (OAuth2 Proxy → Jaeger) |
| `kiali-route` | `kiali.easysolution.work` | `kiali:20001` (Kiali directly) |

Both routes include `external-dns.alpha.kubernetes.io/hostname` and `external-dns.alpha.kubernetes.io/target` annotations so that ExternalDNS automatically creates the corresponding DNS records.

### 3.5 Values (Production)

```yaml
# prod/istio-config/values/istio-config-values.yaml
targetIP: "116.203.203.121"
kialiHostname: kiali.easysolution.work
jaegerHostname: jaeger.easysolution.work

gateway:
  name: main-gateway
  namespace: nginx-gateway

injectedNamespaces:
  - easy-deploy-system

meshConfig:
  mtlsMode: STRICT

tracing:
  enabled: true
  samplingRate: 10

route:
  sections: [http, https]

oauth2Proxy:
  enabled: true
  issuerUrl: https://keycloak.easysolution.work/realms/istio
  clientId: jaeger-proxy
```

---

## Part 4: Jaeger (Distributed Tracing)

Jaeger collects, stores, and visualizes distributed traces from Envoy sidecar proxies.

### How Traces Flow

```
App Pod (Envoy Sidecar)
  │
  │  Zipkin protocol (port 9411)
  ▼
jaeger-collector.istio-system:9411
  │
  │  In-memory storage
  ▼
jaeger.istio-system:16686 (Query UI)
  │
  │  via OAuth2 Proxy
  ▼
jaeger.easysolution.work (external access)
```

### Helm Values (Production)

```yaml
# prod/jaeger/values/jaeger-values.yaml
replicas: 1

config:
  extensions:
    jaeger_storage:
      backends:
        memory_store:
          memory:
            max_traces: 100000
  service:
    extensions: [jaeger_storage]
    pipelines:
      traces:
        receivers: [otlp, jaeger]
        exporters: [jaeger_storage_exporter]

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1Gi
```

**Key settings:**
- `max_traces: 100000` — Maximum number of traces stored in memory (100k for prod, 50k for dev)
- `receivers: [otlp, jaeger]` — Accepts traces via both OpenTelemetry Protocol (OTLP) and Jaeger/Zipkin
- Storage is **in-memory only** — traces are lost on pod restart

> **Note:** For production use with persistent storage, consider configuring Elasticsearch or Cassandra as the storage backend.

---

## Part 5: Kiali (Service Mesh Dashboard)

Kiali provides a web-based dashboard for visualizing the Istio service mesh: traffic flow, service dependencies, configuration validation, and health status.

### Helm Values (Production)

```yaml
# prod/kiali/values/kiali-values.yaml
istio_namespace: istio-system

auth:
  strategy: openid
  openid:
    client_id: kiali
    issuer_uri: https://keycloak.easysolution.work/realms/istio
    scopes: [openid, profile, email]
    username_claim: preferred_username
    disable_rbac: true

deployment:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  ingress:
    enabled: false

server:
  web_fqdn: kiali.easysolution.work
  web_port: 443
  web_schema: https

external_services:
  prometheus:
    url: http://monitoring-kube-prometheus-prometheus.monitoring:9090
  grafana:
    enabled: true
    in_cluster_url: http://monitoring-grafana.monitoring:80
    url: https://grafana.easysolution.work
  tracing:
    enabled: true
    in_cluster_url: http://jaeger.istio-system:16686
    url: https://jaeger.easysolution.work
    use_grpc: false
```

**Key settings:**

| Setting | Description |
|---------|-------------|
| `auth.strategy: openid` | Users authenticate via Keycloak OIDC |
| `auth.openid.disable_rbac: true` | Kiali uses its own ServiceAccount for K8s API calls (no kube-apiserver OIDC required) |
| `deployment.ingress.enabled: false` | Ingress is disabled; access is via the HTTPRoute in `istio-config` |
| `server.web_fqdn` | The public FQDN used for OpenID redirect URIs |
| `external_services.prometheus.url` | Kiali queries Prometheus for service metrics |
| `external_services.grafana.url` | Links to Grafana dashboards from the Kiali UI |
| `external_services.tracing.in_cluster_url` | Kiali queries Jaeger for traces |

> For Keycloak OIDC authentication setup details, see [keycloak-oidc-setup.md](keycloak-oidc-setup.md).

---

## Part 6: Sidecar Injection

Istio injects Envoy sidecar proxies into application pods to enable mTLS, traffic management, and tracing. Sidecar injection is controlled by namespace labels.

### Enable Sidecar Injection for a Namespace

```bash
kubectl label namespace <namespace> istio-injection=enabled
```

### Add Namespace to mTLS STRICT Policy

After enabling sidecar injection, add the namespace to `injectedNamespaces` in the istio-config values so that a `PeerAuthentication` with `STRICT` mTLS is created:

```yaml
# prod/istio-config/values/istio-config-values.yaml
injectedNamespaces:
  - easy-deploy-system
  - <your-new-namespace>     # Add here
```

Push to git and ArgoCD will sync the new `PeerAuthentication` resource.

### Currently Injected Namespaces

| Namespace | mTLS Mode | Purpose |
|-----------|-----------|---------|
| `easy-deploy-system` | STRICT | Application workloads managed by the Easy-Deploy platform |

### Verify Injection

```bash
# Check if namespace has the injection label
kubectl get namespace <namespace> --show-labels | grep istio-injection

# Check if pods have the sidecar (2/2 containers = sidecar present)
kubectl get pods -n <namespace>

# Check sidecar proxy status
istioctl proxy-status
```

### Pod Startup Behavior

With `holdApplicationUntilProxyStarts: true` in the istiod configuration, application containers wait for the Envoy sidecar to be fully ready before starting. This prevents connection errors during pod initialization.

---

## Part 7: External Access via NGINX Gateway

Istio services (Jaeger, Kiali) are exposed externally through **NGINX Gateway Fabric** using Kubernetes Gateway API `HTTPRoute` resources — not Istio's own `Gateway`/`VirtualService`.

### Traffic Flow

```
Internet
  │
  ▼
DNS (external-dns) → jaeger.easysolution.work → Cluster IP
  │
  ▼
NGINX Gateway Fabric (main-gateway, nginx-gateway namespace)
  │
  ▼ HTTPRoute: jaeger-route
  │
OAuth2 Proxy (:4180, istio-system)
  │
  ▼ (authenticated)
  │
Jaeger Query (:16686, istio-system)
```

### Shared Gateway

All HTTPRoutes attach to the same shared gateway:

```yaml
gateway:
  name: main-gateway
  namespace: nginx-gateway
```

This gateway is defined in the `gateway-config` chart and provides:
- HTTP listener on port 80 (redirects to HTTPS)
- HTTPS listener on port 443 with wildcard TLS certificate (`*.easysolution.work`)
- Routes from all namespaces are allowed (`from: All`)

### DNS Automation

Each HTTPRoute has ExternalDNS annotations:

```yaml
annotations:
  external-dns.alpha.kubernetes.io/hostname: jaeger.easysolution.work
  external-dns.alpha.kubernetes.io/target: "116.203.203.121"
```

ExternalDNS automatically creates/updates DNS records based on these annotations.

---

## Part 8: Environment Differences (Prod vs Dev)

| Setting | Production | Development |
|---------|-----------|-------------|
| **Cluster IP** | `116.203.203.121` | `178.104.84.100` |
| **Keycloak** | `keycloak.easysolution.work` | `keycloak-dev.easysolution.work` |
| **Kiali URL** | `kiali.easysolution.work` | `kiali-dev.easysolution.work` |
| **Jaeger URL** | `jaeger.easysolution.work` | `jaeger-dev.easysolution.work` |
| **Grafana URL** | `grafana.easysolution.work` | `grafana-dev.easysolution.work` |
| **Trace Sampling** | 10% | 100% |
| **Jaeger Max Traces** | 100,000 | 50,000 |
| **Istiod CPU request** | 200m | 100m |
| **Istiod Memory request** | 512Mi | 256Mi |
| **Proxy CPU request** | 100m | 50m |
| **Proxy Memory request** | 128Mi | 64Mi |
| **Kiali CPU request** | 100m | 50m |
| **Kiali Memory request** | 256Mi | 128Mi |
| **Kiali `disable_rbac`** | `true` | not set (needs to be added) |

> **Note:** The dev Kiali values do not yet have `disable_rbac: true`. Add it to `dev/kiali/values/kiali-values.yaml` to match the production configuration.

---

## Troubleshooting

### Istiod Not Starting

```bash
kubectl get pods -n istio-system -l app=istiod
kubectl logs -n istio-system -l app=istiod --tail=30
```

| Error | Cause | Fix |
|-------|-------|-----|
| Webhook `failurePolicy` drift | ArgoCD reports OutOfSync | Already handled by `ignoreDifferences` in ArgoCD config |
| OOMKilled | Insufficient memory | Increase istiod memory limits in values |

### Sidecar Not Injected

```bash
# Verify namespace label
kubectl get namespace <ns> -o jsonpath='{.metadata.labels.istio-injection}'
```

If empty, add the label:
```bash
kubectl label namespace <ns> istio-injection=enabled
```

Then restart the pods:
```bash
kubectl rollout restart deployment -n <ns>
```

### mTLS Not Working

```bash
# Check PeerAuthentication resources
kubectl get peerauthentication -A

# Test mTLS between pods
kubectl exec -n <ns> <pod> -c istio-proxy -- \
  openssl s_client -connect <target-service>:<port> -tls1_2
```

### No Traces in Jaeger

1. Verify tracing is enabled:
   ```bash
   kubectl get telemetry -n istio-system
   ```

2. Check that the Jaeger collector is running:
   ```bash
   kubectl get pods -n istio-system -l app.kubernetes.io/name=jaeger
   ```

3. Verify the Zipkin address in istiod config:
   ```bash
   kubectl get cm istio -n istio-system -o yaml | grep zipkin
   ```
   Should show: `address: jaeger-collector.istio-system:9411`

4. Check sidecar proxy config:
   ```bash
   istioctl proxy-config bootstrap <pod-name> -n <namespace> | grep -A5 tracing
   ```

### Kiali Cannot See Services / Traffic

1. Verify Prometheus is accessible from Kiali:
   ```bash
   kubectl exec -n istio-system -l app.kubernetes.io/name=kiali -- \
     curl -s http://monitoring-kube-prometheus-prometheus.monitoring:9090/api/v1/status/config | head -1
   ```

2. Verify Kiali can reach Jaeger:
   ```bash
   kubectl exec -n istio-system -l app.kubernetes.io/name=kiali -- \
     curl -s http://jaeger.istio-system:16686/api/services | head -1
   ```

3. Check Kiali logs:
   ```bash
   kubectl logs -n istio-system -l app.kubernetes.io/name=kiali --tail=30
   ```

### ArgoCD Reports OutOfSync for Istio

This is expected for Istio resources. The `ignoreDifferences` configuration in the ArgoCD Application definitions handles the most common cases (webhook `failurePolicy` drift). If other fields cause sync issues:

```yaml
ignoreDifferences:
  - group: <api-group>
    kind: <resource-kind>
    jqPathExpressions:
      - <path-to-ignore>
```

### OAuth2 Proxy Issues (Jaeger Authentication)

See [keycloak-oidc-setup.md](keycloak-oidc-setup.md) for detailed troubleshooting of:
- 500 Internal Server Error on OAuth2 callback
- Invalid client credentials
- Email not verified errors
- Cookie secret issues

---

## Appendix: Istio Metrics & Prometheus Integration

### What Metrics Are Collected

The `monitoring-config` chart includes ServiceMonitor/PodMonitor resources for Istio:

| Target | Resource Type | Namespace | Port | Path |
|--------|--------------|-----------|------|------|
| **Istiod** | ServiceMonitor | istio-system | `http-monitoring` (15014) | `/metrics` |
| **Envoy sidecars** | PodMonitor | all injected namespaces | `http-envoy-prom` (15090) | `/stats/prometheus` |
| **Kiali** | ServiceMonitor | istio-system | `http-metrics` (9090) | `/metrics` |
| **Jaeger** | ServiceMonitor | istio-system | `metrics` (14269) | `/metrics` |

These are enabled via `monitoring-config` values:

```yaml
serviceMonitors:
  istiod:
    enabled: true
  envoy:
    enabled: true
  kiali:
    enabled: true
  jaeger:
    enabled: true
```

### Key Istio Metrics Available in Prometheus

After deploying the ServiceMonitors, the following metrics become available:

**Istiod (control plane):**
- `pilot_xds_pushes_total` — total config pushes to sidecars
- `pilot_proxy_convergence_time` — time for config to reach all proxies
- `pilot_conflict_inbound_listener` / `pilot_conflict_outbound_listener` — config conflicts
- `pilot_k8s_cfg_events` — Kubernetes config events processed

**Envoy sidecars (data plane):**
- `istio_requests_total` — total requests (with `source`, `destination`, `response_code` labels)
- `istio_request_duration_milliseconds` — request latency histogram
- `istio_tcp_sent_bytes_total` / `istio_tcp_received_bytes_total` — TCP traffic
- `istio_request_bytes` / `istio_response_bytes` — request/response sizes

### How Kiali Uses These Metrics

Kiali reads from Prometheus at `http://monitoring-kube-prometheus-prometheus.monitoring:9090` (configured in Kiali values). It uses `istio_requests_total` and related metrics to display:
- Traffic flow graphs between services
- Request rates, error rates, and latencies (RED metrics)
- TCP traffic statistics
- Health status of services

> **Without these ServiceMonitors, Kiali will show services but without traffic metrics.** The service mesh topology will still be visible (from Envoy configuration), but rate/error/duration data will be missing.
