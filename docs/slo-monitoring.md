# SLO monitoring — Sloth-style error budgets

Every service in the mesh gets an availability and a latency SLO, with error
budgets and multiwindow multi-burn-rate alerts, plus a Grafana dashboard to
search services and instances by their SLO state.

| Piece | Where |
|-------|-------|
| SLO recording rules + alerts | `charts/monitoring-config/templates/prometheusrules/slo-rules.yaml` |
| Rule generation logic | `charts/monitoring-config/templates/_helpers.tpl` |
| Dashboard JSON | `charts/monitoring-config/dashboards/service-instance-slo.json` |
| Dashboard generator | `scripts/build-slo-dashboard.py` |
| Configuration | `slo:` block in `charts/monitoring-config/values.yaml` |

---

## Why Sloth-style, without Sloth

[Sloth](https://sloth.dev) turns a short SLO spec into a large, carefully-shaped
set of Prometheus rules: SLI ratios recorded at seven windows, an error budget,
burn rates, and the Google SRE workbook's multiwindow alerts. The *rules* are the
valuable part; the controller is just a generator.

Running the controller would mean a new ArgoCD application, a CRD, and an operator
to keep alive — and it would still need one hand-written `PrometheusServiceLevel`
per service, which defeats the point of a platform where apps arrive as a one-line
YAML.

So this chart emits the same rules directly. Same metric names, same windows,
same alert thresholds — Sloth-compatible series, no new component.

**The one deviation:** Sloth stamps a static `sloth_service` label on each SLO,
because each SLO is hand-declared. Here the SLO set is *discovered* by grouping
Istio telemetry, so identity lives in the native Istio labels
(`destination_workload_namespace`, `destination_canonical_service`, and at
instance level `destination_workload`). `sloth_slo`, `sloth_window`,
`sloth_level` and `sloth_period` are still attached.

The practical consequence: **a new app deployed through BasePlate-Dev is under SLO
from its first request.** No chart change, no values entry.

---

## What gets recorded

For each of the four combinations (service/instance × availability/latency):

| Series | Meaning |
|--------|---------|
| `slo:sli_error:ratio_rate5m` … `ratio_rate3d` | Bad-event share over 5m, 30m, 1h, 2h, 6h, 1d, 3d |
| `slo:sli_error:ratio_rate30d` | The period SLI, averaged from the 5m series |
| `slo:objective:ratio` | The objective, e.g. `0.999` |
| `slo:error_budget:ratio` | `1 - objective`, e.g. `0.001` |
| `slo:current_burn_rate:ratio` | 5m SLI ÷ budget |
| `slo:period_burn_rate:ratio` | 30d SLI ÷ budget |
| `slo:period_error_budget_remaining:ratio` | `1 - period burn rate` |

The 30d SLI is averaged from the already-recorded 5m series rather than ranged
over the raw counter — a `rate(...[30d])` on every evaluation would make
Prometheus walk a month of samples each time. This is Sloth's own optimization.

### The SLIs

**Availability** — share of requests answered `5xx`:

```promql
sum by (…) (rate(istio_requests_total{reporter="destination", response_code=~"5.."}[5m]))
/ sum by (…) (rate(istio_requests_total{reporter="destination"}[5m]))
```

`4xx` is deliberately *not* counted. A client sending a bad request is not the
service failing, and counting it would let one misbehaving caller burn a budget
the owning team cannot defend.

**Latency** — share of requests slower than `slo.latency.thresholdMs`, read off
the histogram as (all requests − requests within the bucket).

> `thresholdMs` **must** be an existing `le` bucket boundary of
> `istio_request_duration_milliseconds`. Prometheus does not interpolate: an
> unknown `le` matches nothing and the SLI silently reads as 100% error.
> Istio's default boundaries include `0.5, 1, 5, 10, 25, 50, 100, 250, 500,
> 1000, 2500, 5000, 10000`.

### Why `reporter=~"waypoint|destination"`

Between two meshed pods the request is reported twice — once by the caller's
proxy, once by the callee's. Without this selector every ratio is computed over
inflated totals.

Which reporter counts the request once depends on the data plane:

| Data plane | Emits `istio_requests_total`? | `reporter` |
| --- | --- | --- |
| Waypoint proxy (ambient, L7) | yes | `waypoint` |
| ztunnel (ambient, L4) | **no** — `istio_tcp_*` only | — |
| Sidecar | yes | `destination` |

A waypoint-fronted request is never *also* reported as `destination`, so matching
both values keeps the count at once per request while covering either shape.

> **Ambient services with no waypoint get no SLO.** ztunnel does not produce HTTP
> metrics, so there is nothing to build an availability or latency SLI from.
> Attaching a waypoint is what brings a service under SLO.

Filtering on `reporter="destination"` alone — the natural choice on a sidecar
mesh — silently yields an empty dashboard here: no series, and the Namespace /
Service / Instance variables come up with no values at all.

---

## The alerts

Two severities, each pairing a short window with a long one. The short window
makes the alert fast; the long window makes it stick — an outage has to be both
happening *now* and sustained enough to matter before it pages.

| Alert | Severity | Fires when | Meaning |
|-------|----------|-----------|---------|
| `SlothSLOErrorBudgetBurnPage` | critical | 14.4× over 5m **and** 1h, **or** 6× over 30m **and** 6h | The 30d budget is gone in ~2 days. Wake someone. |
| `SlothSLOErrorBudgetBurnTicket` | warning | 3× over 2h **and** 1d, **or** 1× over 6h **and** 3d | Slow grind. File it, fix it this week. |

The two or'd branches catch different failure shapes: a violent short burn and a
slow one that a single short window would miss.

Alerts fire at both service and instance level, so a single bad pod inside an
otherwise healthy pool pages on its own rather than being averaged away.

---

## The dashboard

**Service & Instance SLO (Sloth)** — uid `service-instance-slo`.

The top two panels are the search surface: every service, and every instance,
with its live SLO state. Both tables have filterable columns and sortable
headers, and open sorted by worst remaining error budget — the dashboard opens
on whatever is on fire. The `Namespace` / `Service` / `Instance` variables narrow
these and every panel below.

Below that, per SLO: the headline numbers as stat tiles, burn rate across the
same windows the alerts evaluate, error budget over time, then a per-instance
breakdown and the raw traffic the SLIs are derived from.

Burn rate and error budget are always separate panels — they share no scale, and
a dual axis would misrepresent both.

### Regenerating it

The JSON is generated, not hand-edited (it is the same panel set repeated across
two SLOs and two levels — hand-editing 900 lines of JSON is where dashboards rot):

```bash
python3 scripts/build-slo-dashboard.py
```

It writes `charts/monitoring-config/dashboards/service-instance-slo.json`
directly. Commit the result; ArgoCD picks it up as a ConfigMap via the
`dashboards/*.json` glob in `templates/dashboards/dashboards.yaml`.

---

## Configuration

```yaml
slo:
  enabled: true
  period: 30d
  selector: 'reporter="destination"'
  instanceLevel:
    enabled: true          # per-pod SLOs alongside per-service
  availability:
    objective: 99.9        # ~43m of budget per 30d
  latency:
    objective: 99.0
    thresholdMs: 500       # must be an le bucket boundary
  alerts:
    enabled: true
    page: { severity: critical }
    ticket: { severity: warning }
```

To keep infra chatter out of app SLOs, extend the selector:

```yaml
selector: 'reporter="destination", destination_workload_namespace!~"istio-system|monitoring"'
```

### Cost

Instance-level SLOs cost one extra series set per pod. If cardinality becomes a
problem, `slo.instanceLevel.enabled: false` halves the rule count — at the cost
of losing the "one bad pod in a healthy pool" signal, which is usually the reason
you went looking.

---

## Verifying a change

```bash
helm lint charts/monitoring-config -f prod/monitoring-config/values/monitoring-config-values.yaml
helm template test charts/monitoring-config \
  -f prod/monitoring-config/values/monitoring-config-values.yaml \
  -s templates/prometheusrules/slo-rules.yaml
```

Rendered rules land in the `monitoring` namespace and are picked up by
kube-prometheus-stack's `ruleSelector`. Confirm in Prometheus under
**Status → Rules**, group `sloth-slo-*`.

Recording rules need one evaluation interval before they return anything, and
`slo:sli_error:ratio_rate30d` needs the 5m series to have existed for a while —
expect the 30d panels to be thin on a fresh cluster and to fill in over the
first month.
