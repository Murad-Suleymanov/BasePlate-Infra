#!/usr/bin/env python3
"""Build the Sloth SLO Grafana dashboard JSON.

Written as a generator rather than hand-authored JSON because the dashboard is
highly repetitive (the same panel set for availability and latency, at service
and instance level) and hand-editing 900 lines of JSON is where dashboards rot.
Output is committed; this script is the source of truth for regenerating it.
"""
import json

DS = {"type": "prometheus", "uid": "prometheus"}

# Label selector shared by every query. Mirrors slo.selector in values.yaml.
SEL_SVC = 'sloth_level="service", destination_workload_namespace=~"$namespace", destination_canonical_service=~"$service"'
SEL_INST = 'sloth_level="instance", destination_workload_namespace=~"$namespace", destination_canonical_service=~"$service", destination_workload=~"$instance"'
ISTIO_SVC = 'reporter="destination", destination_workload_namespace=~"$namespace", destination_canonical_service=~"$service"'
ISTIO_INST = ISTIO_SVC + ', destination_workload=~"$instance"'

# Status thresholds. These are reserved SLO-state colors — never used to tell
# one series from another, which is what palette-classic is for.
TH_BUDGET = {  # % of error budget left
    "mode": "absolute",
    "steps": [
        {"color": "red", "value": None},
        {"color": "orange", "value": 10},
        {"color": "yellow", "value": 25},
        {"color": "green", "value": 50},
    ],
}
TH_SLI = {  # achieved SLI, %
    "mode": "absolute",
    "steps": [
        {"color": "red", "value": None},
        {"color": "orange", "value": 99},
        {"color": "yellow", "value": 99.5},
        {"color": "green", "value": 99.9},
    ],
}
TH_BURN = {  # burn rate multiple; mirrors the alert windows (1x, 6x, 14.4x)
    "mode": "absolute",
    "steps": [
        {"color": "green", "value": None},
        {"color": "yellow", "value": 1},
        {"color": "orange", "value": 6},
        {"color": "red", "value": 14.4},
    ],
}

_id = [0]


def nid():
    _id[0] += 1
    return _id[0]


def target(expr, legend=None, ref="A", instant=False, fmt=None):
    t = {"datasource": DS, "editorMode": "code", "expr": expr, "refId": ref}
    if legend is not None:
        t["legendFormat"] = legend
    if instant:
        t["instant"] = True
        t["range"] = False
    if fmt:
        t["format"] = fmt
    return t


def row(title, y):
    return {
        "collapsed": False,
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": y},
        "id": nid(),
        "panels": [],
        "title": title,
        "type": "row",
    }


def stat(title, expr, x, y, w, h, thresholds, unit, decimals=3, desc=""):
    return {
        "datasource": DS,
        "description": desc,
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "decimals": decimals,
                "mappings": [],
                "thresholds": thresholds,
                "unit": unit,
            },
            "overrides": [],
        },
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "id": nid(),
        "options": {
            "colorMode": "value",
            "graphMode": "area",
            "justifyMode": "auto",
            "orientation": "auto",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "textMode": "auto",
        },
        "pluginVersion": "10.0.0",
        "targets": [target(expr)],
        "title": title,
        "type": "stat",
    }


def ts(title, targets, x, y, w, h, unit, desc="", thresholds=None,
       fill=8, minv=None, maxv=None, stack=False):
    """Timeseries. 2px lines and a recessive fill keep the marks thin; color
    comes from palette-classic so identity follows the series, not its rank."""
    custom = {
        "axisCenteredZero": False,
        "axisColorMode": "text",
        "axisLabel": "",
        "axisPlacement": "auto",
        "barAlignment": 0,
        "drawStyle": "line",
        "fillOpacity": fill,
        "gradientMode": "none",
        "hideFrom": {"legend": False, "tooltip": False, "viz": False},
        "lineInterpolation": "smooth",
        "lineWidth": 2,
        "pointSize": 8,
        "scaleDistribution": {"type": "linear"},
        "showPoints": "never",
        "spanNulls": True,
        "stacking": {"group": "A", "mode": "normal" if stack else "none"},
        "thresholdsStyle": {"mode": "dashed" if thresholds else "off"},
    }
    defaults = {
        "color": {"mode": "palette-classic"},
        "custom": custom,
        "mappings": [],
        "thresholds": thresholds or {"mode": "absolute", "steps": [{"color": "green", "value": None}]},
        "unit": unit,
    }
    if minv is not None:
        defaults["min"] = minv
    if maxv is not None:
        defaults["max"] = maxv
    return {
        "datasource": DS,
        "description": desc,
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "id": nid(),
        "options": {
            # A legend is always present for >= 2 series, so identity is never
            # carried by color alone.
            "legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table",
                       "placement": "right", "showLegend": True},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "pluginVersion": "10.0.0",
        "targets": targets,
        "title": title,
        "type": "timeseries",
    }


def slo_table(title, x, y, w, h, level, desc):
    """The search surface: one row per service (or instance), every SLO number
    beside it, sortable and filterable in place.

    Each query is instant + table format, so every frame is
    (Time, <labels...>, Value). `merge` joins them on the shared label columns,
    then `organize` drops Time and names the value columns.
    """
    sel = SEL_SVC if level == "service" else SEL_INST
    istio = ISTIO_SVC if level == "service" else ISTIO_INST
    by = "destination_workload_namespace, destination_canonical_service"
    if level == "instance":
        by += ", destination_workload"

    targets = [
        target(f'100 * (1 - slo:sli_error:ratio_rate30d{{sloth_slo="availability", {sel}}})',
               ref="A", instant=True, fmt="table"),
        target(f'100 * slo:period_error_budget_remaining:ratio{{sloth_slo="availability", {sel}}}',
               ref="B", instant=True, fmt="table"),
        target(f'slo:current_burn_rate:ratio{{sloth_slo="availability", {sel}}}',
               ref="C", instant=True, fmt="table"),
        target(f'100 * (1 - slo:sli_error:ratio_rate30d{{sloth_slo="latency", {sel}}})',
               ref="D", instant=True, fmt="table"),
        target(f'100 * slo:period_error_budget_remaining:ratio{{sloth_slo="latency", {sel}}}',
               ref="E", instant=True, fmt="table"),
        target(f'sum by ({by}) (rate(istio_requests_total{{{istio}}}[5m]))',
               ref="F", instant=True, fmt="table"),
    ]

    rename = {
        "destination_workload_namespace": "Namespace",
        "destination_canonical_service": "Service",
        "destination_workload": "Instance",
        "Value #A": "Avail SLI 30d",
        "Value #B": "Avail budget left",
        "Value #C": "Avail burn rate",
        "Value #D": "Latency SLI 30d",
        "Value #E": "Latency budget left",
        "Value #F": "Req/s",
    }
    exclude = {"Time": True, "Time 1": True, "Time 2": True, "Time 3": True,
               "Time 4": True, "Time 5": True, "Time 6": True}

    def ov(name, unit, thresholds, decimals, mode="color-background"):
        return {
            "matcher": {"id": "byName", "options": name},
            "properties": [
                {"id": "unit", "value": unit},
                {"id": "decimals", "value": decimals},
                {"id": "thresholds", "value": thresholds},
                {"id": "custom.cellOptions", "value": {"type": mode}},
            ],
        }

    return {
        "datasource": DS,
        "description": desc,
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "custom": {"align": "auto", "cellOptions": {"type": "auto"},
                           "filterable": True, "inspect": False},
                "mappings": [],
                "thresholds": {"mode": "absolute", "steps": [{"color": "text", "value": None}]},
            },
            "overrides": [
                ov("Avail SLI 30d", "percent", TH_SLI, 3),
                ov("Latency SLI 30d", "percent", TH_SLI, 3),
                ov("Avail budget left", "percent", TH_BUDGET, 1),
                ov("Latency budget left", "percent", TH_BUDGET, 1),
                ov("Avail burn rate", "none", TH_BURN, 2),
                {"matcher": {"id": "byName", "options": "Req/s"},
                 "properties": [{"id": "unit", "value": "reqps"}, {"id": "decimals", "value": 2}]},
            ],
        },
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "id": nid(),
        "options": {
            "cellHeight": "sm",
            "footer": {"countRows": False, "fields": "", "reducer": ["sum"], "show": False},
            "showHeader": True,
            # Worst error budget first — the table opens on whatever is on fire.
            "sortBy": [{"desc": False, "displayName": "Avail budget left"}],
        },
        "pluginVersion": "10.0.0",
        "targets": targets,
        "title": title,
        "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {"excludeByName": exclude,
                                           "indexByName": {},
                                           "renameByName": rename}},
        ],
        "type": "table",
    }


def slo_section(slo, y, objective_note):
    """The three-panel read on one SLO: where it stands, how fast it is going,
    and what it has left. Burn rate and budget are separate panels on purpose —
    they share no scale, and a dual axis would be a lie."""
    sel = f'sloth_slo="{slo}", {SEL_SVC}'
    p = []
    p.append(stat(
        f"{slo.title()} SLI (30d)",
        f'100 * (1 - max(slo:sli_error:ratio_rate30d{{{sel}}}))',
        0, y, 4, 5, TH_SLI, "percent", 3,
        f"Achieved {slo} over the 30d period, worst of the selected services. {objective_note}"))
    p.append(stat(
        "Error budget left (30d)",
        f'100 * min(slo:period_error_budget_remaining:ratio{{{sel}}})',
        4, y, 4, 5, TH_BUDGET, "percent", 1,
        "Share of the 30d budget still unspent. Below 0 means the SLO is already breached for this period."))
    p.append(stat(
        "Current burn rate (5m)",
        f'max(slo:current_burn_rate:ratio{{{sel}}})',
        8, y, 4, 5, TH_BURN, "none", 2,
        "1x spends the budget exactly over 30d. 6x is the ticket threshold, 14.4x pages — the budget is gone in ~2 days."))
    p.append(ts(
        "Error budget remaining over time",
        [target(f'100 * slo:period_error_budget_remaining:ratio{{{sel}}}',
                "{{destination_canonical_service}}")],
        12, y, 12, 5, "percent",
        "The line that matters: a budget trending to zero is a breach you can see coming.",
        thresholds={"mode": "absolute", "steps": [
            {"color": "red", "value": None}, {"color": "green", "value": 0}]}))

    # Burn rate across the alert's own windows, so what the dashboard shows and
    # what the alert evaluates are the same numbers.
    # Both sides reduce to a single destination_canonical_service label, so this
    # is a plain 1:1 vector match — no ignoring()/group_left needed. Dividing by
    # the recorded budget series rather than a literal keeps the panel correct
    # when the objective in values.yaml changes.
    burn = [target(f'max by (destination_canonical_service) (slo:sli_error:ratio_rate{w}{{{sel}}}) '
                   f'/ max by (destination_canonical_service) (slo:error_budget:ratio{{{sel}}})',
                   "{{destination_canonical_service}} " + w, ref=r)
            for w, r in [("5m", "A"), ("1h", "B"), ("6h", "C"), ("3d", "D")]]
    p.append(ts(
        "Burn rate by alert window",
        burn, 0, y + 5, 12, 7, "none",
        "The same windows the burn-rate alerts use. Dashed lines are the ticket (6x) and page (14.4x) thresholds.",
        thresholds={"mode": "absolute", "steps": [
            {"color": "green", "value": None},
            {"color": "orange", "value": 6},
            {"color": "red", "value": 14.4}]},
        fill=0, minv=0))
    p.append(ts(
        "SLI error ratio (5m)",
        [target(f'100 * slo:sli_error:ratio_rate5m{{{sel}}}',
                "{{destination_canonical_service}}")],
        12, y + 5, 12, 7, "percent",
        "Raw bad-event share per service — the input every window above is built from.",
        minv=0))
    return p


panels = []
y = 0

panels.append(row("Search — services and instances under SLO", y)); y += 1
panels.append(slo_table(
    "Services", 0, y, 24, 8, "service",
    "Every service Istio is reporting traffic for, with its live SLO state. "
    "Type in a column filter to search; click a header to sort. "
    "The variables above narrow this and every panel below."))
y += 8
panels.append(slo_table(
    "Instances", 0, y, 24, 8, "instance",
    "The same numbers per workload. A pool can sit comfortably inside its SLO "
    "while one instance in it burns budget — the service-level row averages that away, this one does not."))
y += 8

panels.append(row("Availability SLO — 5xx responses", y)); y += 1
panels += slo_section("availability", y, "Objective: slo.availability.objective in values.yaml.")
y += 12

panels.append(row("Latency SLO — requests slower than the threshold", y)); y += 1
panels += slo_section("latency", y, "Objective: slo.latency.objective over slo.latency.thresholdMs.")
y += 12

panels.append(row("Per-instance breakdown", y)); y += 1
panels.append(ts(
    "Availability error ratio per instance",
    [target(f'100 * slo:sli_error:ratio_rate5m{{sloth_slo="availability", {SEL_INST}}}',
            "{{destination_workload}}")],
    0, y, 12, 8, "percent",
    "Which pod is actually serving the 5xx. A single bad instance shows up here long before the pool SLO moves.",
    minv=0))
panels.append(ts(
    "Latency error ratio per instance",
    [target(f'100 * slo:sli_error:ratio_rate5m{{sloth_slo="latency", {SEL_INST}}}',
            "{{destination_workload}}")],
    12, y, 12, 8, "percent",
    "Share of requests over the latency threshold, per pod.",
    minv=0))
y += 8
panels.append(ts(
    "P95 latency per instance",
    [target('histogram_quantile(0.95, sum by (le, destination_workload) '
            f'(rate(istio_request_duration_milliseconds_bucket{{{ISTIO_INST}}}[5m])))',
            "{{destination_workload}}")],
    0, y, 12, 8, "ms",
    "The distribution behind the latency SLI. The SLI counts threshold breaches; this shows how far past it they land.",
    minv=0))
panels.append(ts(
    "Request rate per instance",
    [target(f'sum by (destination_workload) (rate(istio_requests_total{{{ISTIO_INST}}}[5m]))',
            "{{destination_workload}}")],
    12, y, 12, 8, "reqps",
    "Traffic split across the pool. An instance with a bad SLI and near-zero traffic is a different problem than one under load.",
    minv=0))
y += 8

panels.append(row("Raw traffic", y)); y += 1
panels.append(ts(
    "Request rate by response code",
    [target(f'sum by (response_code) (rate(istio_requests_total{{{ISTIO_SVC}}}[5m]))',
            "{{response_code}}")],
    0, y, 12, 8, "reqps",
    "Unaggregated traffic by status code — the ground truth the availability SLI is derived from.",
    fill=20, stack=True, minv=0))
panels.append(ts(
    "Request duration quantiles",
    [target('histogram_quantile(0.50, sum by (le) '
            f'(rate(istio_request_duration_milliseconds_bucket{{{ISTIO_SVC}}}[5m])))', "p50", ref="A"),
     target('histogram_quantile(0.95, sum by (le) '
            f'(rate(istio_request_duration_milliseconds_bucket{{{ISTIO_SVC}}}[5m])))', "p95", ref="B"),
     target('histogram_quantile(0.99, sum by (le) '
            f'(rate(istio_request_duration_milliseconds_bucket{{{ISTIO_SVC}}}[5m])))', "p99", ref="C")],
    12, y, 12, 8, "ms",
    "Latency distribution across the selected services.",
    fill=0, minv=0))


def var(name, query, label, desc, multi=True):
    return {
        "current": {"selected": True, "text": ["All"], "value": ["$__all"]},
        "datasource": DS,
        "definition": query,
        "description": desc,
        "hide": 0,
        "includeAll": True,
        "label": label,
        "multi": multi,
        "name": name,
        "options": [],
        "query": {"query": query, "refId": f"{name}-variable"},
        "refresh": 2,  # on time-range change, so the list follows the window
        "regex": "",
        "skipUrlSync": False,
        "sort": 1,
        "type": "query",
    }


dashboard = {
    "annotations": {"list": []},
    "description": (
        "Sloth-style SLO monitoring for every service in the mesh. Search a service or "
        "instance in the tables at the top, or narrow with the variables. "
        "Generated by charts/monitoring-config/templates/prometheusrules/slo-rules.yaml."
    ),
    "editable": True,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 1,  # shared crosshair across panels
    "id": None,
    "links": [],
    "liveNow": False,
    "panels": panels,
    "refresh": "30s",
    "schemaVersion": 38,
    "tags": ["slo", "sloth", "istio", "easy-deploy"],
    "templating": {
        "list": [
            var("namespace",
                'label_values(slo:sli_error:ratio_rate5m{sloth_level="service"}, destination_workload_namespace)',
                "Namespace", "Namespaces with services currently under SLO."),
            var("service",
                'label_values(slo:sli_error:ratio_rate5m{sloth_level="service", destination_workload_namespace=~"$namespace"}, destination_canonical_service)',
                "Service", "Type to search. Narrows every panel below."),
            var("instance",
                'label_values(slo:sli_error:ratio_rate5m{sloth_level="instance", destination_workload_namespace=~"$namespace", destination_canonical_service=~"$service"}, destination_workload)',
                "Instance", "Workloads behind the selected services."),
        ]
    },
    "time": {"from": "now-6h", "to": "now"},
    "timepicker": {},
    "timezone": "",
    "title": "Service & Instance SLO (Sloth)",
    "uid": "service-instance-slo",
    "version": 1,
    "weekStart": "",
}

out = "/Users/suleymanovmurad/Projects/Easy Solution/BasePlate-Infra/charts/monitoring-config/dashboards/service-instance-slo.json"
with open(out, "w") as f:
    json.dump(dashboard, f, indent=2)
    f.write("\n")
print(f"wrote {out}")
print(f"panels={len([p for p in panels if p['type'] != 'row'])} rows={len([p for p in panels if p['type'] == 'row'])}")
