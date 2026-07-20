{{/*
  Sloth-style SLO rule generation.

  These helpers emit the exact rule shape that sloth.dev generates from a
  PrometheusServiceLevel spec — same metric names (slo:sli_error:ratio_rateXX,
  slo:objective:ratio, slo:error_budget:ratio, slo:current_burn_rate:ratio,
  slo:period_burn_rate:ratio, slo:period_error_budget_remaining:ratio) and the
  same multiwindow multi-burn-rate alert windows — without running the Sloth
  controller or its CRD.

  The one deviation from upstream Sloth: Sloth pins a static sloth_service /
  sloth_slo label per declared SLO, because each SLO is hand-declared. Here the
  SLO set is *discovered* from Istio telemetry, so the identity of the object
  under SLO lives in its native Istio labels (destination_workload_namespace,
  destination_canonical_service and, at instance level, destination_workload).
  The static sloth_slo / sloth_window / sloth_level / sloth_period labels are
  still attached so the series stay Sloth-compatible and self-describing.
*/}}

{{/*
  monitoring-config.sloth.windows — the rate windows every SLI is recorded at.
  5m..3d feed the burn-rate alerts; the 30d period window is derived from the 5m
  series (see below) rather than ranged directly over the raw counter.
*/}}
{{- define "monitoring-config.sloth.windows" -}}
5m,30m,1h,2h,6h,1d,3d
{{- end -}}

{{/*
  monitoring-config.sloth.ruleGroup — one full SLO rule group.

  Expects a dict with:
    level      — "service" or "instance" (becomes the sloth_level label)
    by         — comma-separated group-by labels
    slo        — SLO name (becomes the sloth_slo label)
    objective  — objective as a percentage, e.g. 99.9
    errorExpr  — error-events query, with the literal WINDOW as rate-range placeholder
    totalExpr  — valid-events query, same placeholder
    period     — error-budget period, e.g. 30d
    alerts     — the .Values.slo.alerts subtree
*/}}
{{- define "monitoring-config.sloth.ruleGroup" -}}
{{/*
  divf/subf, not div/sub: sprig's div is integer division, so the usual
  (100 - 99.9) / 100 truncates to 0 — an error budget of zero, a burn rate of
  x/0, and alert thresholds that fire on everything. Every arithmetic op here
  must stay in float.

  %g then trims the binary-float noise (0.0009999999999999432 -> 0.001) so the
  rendered PromQL is readable and diffs stay stable.
*/}}
{{- $budget := divf (subf 100.0 (float64 .objective)) 100.0 -}}
{{- $budgetStr := printf "%g" $budget -}}
{{- $group := printf "sloth-slo-%s-%s" .level .slo -}}
- name: {{ $group }}
  rules:
{{- range $w := splitList "," (include "monitoring-config.sloth.windows" .) }}
    - record: slo:sli_error:ratio_rate{{ $w }}
      expr: |-
        ({{ $.errorExpr | replace "WINDOW" $w }})
        /
        ({{ $.totalExpr | replace "WINDOW" $w }})
      labels:
        sloth_slo: {{ $.slo | quote }}
        sloth_level: {{ $.level | quote }}
        sloth_window: {{ $w | quote }}
{{- end }}
    {{/*
      Period (30d) SLI. Sloth avoids a 30d range over the raw counter — which
      would force Prometheus to walk a month of samples on every evaluation —
      by averaging the already-recorded 5m ratio across the period instead.
      ignoring(sloth_window) drops the 5m label so the quotient is unlabelled
      by window, then the rule stamps sloth_window={{ .period }} back on.
    */}}
    - record: slo:sli_error:ratio_rate{{ .period }}
      expr: |-
        sum_over_time(slo:sli_error:ratio_rate5m{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"}[{{ .period }}])
        / ignoring (sloth_window)
        count_over_time(slo:sli_error:ratio_rate5m{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"}[{{ .period }}])
      labels:
        sloth_slo: {{ .slo | quote }}
        sloth_level: {{ .level | quote }}
        sloth_window: {{ .period | quote }}
    {{/*
      Objective and error budget are constants, but they are recorded as series
      so dashboards can join them against the SLI without hardcoding thresholds.
      Multiplying the 5m SLI by 0 is how we mint a constant that carries exactly
      the label set of the objects actually under SLO — a service that stopped
      serving traffic drops out of these series too, instead of lingering.
    */}}
    - record: slo:objective:ratio
      expr: |-
        (max without (sloth_window) (slo:sli_error:ratio_rate5m{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"}) * 0)
        + {{ printf "%g" (divf (float64 .objective) 100.0) }}
      labels:
        sloth_slo: {{ .slo | quote }}
        sloth_level: {{ .level | quote }}
        sloth_period: {{ .period | quote }}
    - record: slo:error_budget:ratio
      expr: |-
        (max without (sloth_window) (slo:sli_error:ratio_rate5m{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"}) * 0)
        + {{ $budgetStr }}
      labels:
        sloth_slo: {{ .slo | quote }}
        sloth_level: {{ .level | quote }}
        sloth_period: {{ .period | quote }}
    {{/*
      Burn rate = how many times faster than "exactly on budget" the SLO is
      being consumed. 1 means the budget lasts exactly the period; 14.4 means
      it is gone in ~2 days. Divided by the literal budget rather than joined
      against slo:error_budget:ratio — same number, no vector match to break.
    */}}
    - record: slo:current_burn_rate:ratio
      expr: |-
        max without (sloth_window) (slo:sli_error:ratio_rate5m{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"})
        / {{ $budgetStr }}
      labels:
        sloth_slo: {{ .slo | quote }}
        sloth_level: {{ .level | quote }}
        sloth_period: {{ .period | quote }}
    - record: slo:period_burn_rate:ratio
      expr: |-
        max without (sloth_window) (slo:sli_error:ratio_rate{{ .period }}{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"})
        / {{ $budgetStr }}
      labels:
        sloth_slo: {{ .slo | quote }}
        sloth_level: {{ .level | quote }}
        sloth_period: {{ .period | quote }}
    - record: slo:period_error_budget_remaining:ratio
      expr: |-
        1 - slo:period_burn_rate:ratio{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"}
      labels:
        sloth_slo: {{ .slo | quote }}
        sloth_level: {{ .level | quote }}
        sloth_period: {{ .period | quote }}
{{- if .alerts.enabled }}
    {{/*
      Multiwindow multi-burn-rate alerts, straight from the Google SRE workbook
      and matching Sloth's defaults for a 30d period.

      Each severity pairs a short window with a long one: the short window makes
      the alert fast, the long window makes it stick — an outage has to be both
      happening *now* and sustained enough to matter before it pages. The two
      or'd branches catch different failure shapes: a violent short burn (14.4x
      over 5m+1h eats the month's budget in two days) and a slower grind
      (6x over 30m+6h).
    */}}
    - alert: SlothSLOErrorBudgetBurnPage
      expr: |-
        (
          max without (sloth_window) (slo:sli_error:ratio_rate5m{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"} > ({{ printf "%g" (mulf 14.4 $budget) }}))
          and
          max without (sloth_window) (slo:sli_error:ratio_rate1h{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"} > ({{ printf "%g" (mulf 14.4 $budget) }}))
        )
        or
        (
          max without (sloth_window) (slo:sli_error:ratio_rate30m{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"} > ({{ printf "%g" (mulf 6.0 $budget) }}))
          and
          max without (sloth_window) (slo:sli_error:ratio_rate6h{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"} > ({{ printf "%g" (mulf 6.0 $budget) }}))
        )
      labels:
        severity: {{ .alerts.page.severity }}
        sloth_severity: page
        sloth_slo: {{ .slo | quote }}
        sloth_level: {{ .level | quote }}
      annotations:
        summary: {{ printf "%s SLO of %s is burning its error budget fast" (.slo | title) .level | quote }}
        description: {{ printf "{{ $labels.destination_canonical_service }} in {{ $labels.destination_workload_namespace }}%s is burning the %s error budget at a paging rate. At this speed the %s budget is exhausted in ~2 days." (ternary " (instance {{ $labels.destination_workload }})" "" (eq .level "instance")) .slo .period | quote }}
    - alert: SlothSLOErrorBudgetBurnTicket
      expr: |-
        (
          max without (sloth_window) (slo:sli_error:ratio_rate2h{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"} > ({{ printf "%g" (mulf 3.0 $budget) }}))
          and
          max without (sloth_window) (slo:sli_error:ratio_rate1d{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"} > ({{ printf "%g" (mulf 3.0 $budget) }}))
        )
        or
        (
          max without (sloth_window) (slo:sli_error:ratio_rate6h{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"} > ({{ printf "%g" (mulf 1.0 $budget) }}))
          and
          max without (sloth_window) (slo:sli_error:ratio_rate3d{sloth_slo="{{ .slo }}", sloth_level="{{ .level }}"} > ({{ printf "%g" (mulf 1.0 $budget) }}))
        )
      labels:
        severity: {{ .alerts.ticket.severity }}
        sloth_severity: ticket
        sloth_slo: {{ .slo | quote }}
        sloth_level: {{ .level | quote }}
      annotations:
        summary: {{ printf "%s SLO of %s is slowly eating its error budget" (.slo | title) .level | quote }}
        description: {{ printf "{{ $labels.destination_canonical_service }} in {{ $labels.destination_workload_namespace }}%s is burning the %s error budget faster than the %s period allows. Not paging, but it will breach the SLO if left alone." (ternary " (instance {{ $labels.destination_workload }})" "" (eq .level "instance")) .slo .period | quote }}
{{- end }}
{{- end -}}
