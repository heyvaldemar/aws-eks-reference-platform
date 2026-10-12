# 8. Traces become span metrics; no tracing backend yet

- Status: accepted
- Date: 2026-10-11

## Context

Observability has to be proven, not just installed: metrics scraped, and traces leaving the workload and arriving somewhere. Running a tracing backend (Tempo, Jaeger) means storage, retention and another UI on every cluster, including the kind runner with about 7 GB of memory.

## Decision

- kube-prometheus-stack for Prometheus, its operator, Grafana and kube-state-metrics. Prometheus selects every ServiceMonitor in the cluster, not only those labelled for its release. node-exporter is off: it needs host namespaces the restricted Pod Security level forbids, and kubelet and cAdvisor metrics cover nodes.
- One OpenTelemetry Collector (contrib distribution) receives OTLP, turns spans into request, error and duration metrics with the `spanmetrics` connector, and exposes them to Prometheus.
- Workloads send traces with the standard `OTEL_EXPORTER_OTLP_ENDPOINT`; nothing in them names a backend.
- Grafana's admin password is generated in the cluster by an External Secrets Password generator, and is in no file.
- The e2e suite queries Prometheus for the demo's scrape targets and for span metrics after sending traffic.

## Consequences

- "Are traces arriving" is a PromQL query, and RED metrics per service exist without instrumenting metrics by hand.
- Individual traces are not kept. Adding Tempo is one more exporter in the collector's pipeline and one ApplicationSet; nothing in the workloads changes.
- Alertmanager runs on EKS only; kind has nobody to page.

## Alternatives

- **Tempo or Jaeger now.** Full traces, at the cost of storage and memory on every cluster before anyone needs them.
- **A vendor backend.** The collector's exporter is the only thing that changes, which is why the workloads speak OTLP to the collector and not to a vendor.

## How to explain this to a customer

Your services report how many requests they serve, how many fail and how long they take, without your developers writing that code, because it is derived from the traces they already send. Everything flows through one standard collector, so sending traces to Datadog, Grafana Cloud or your own Tempo later is a configuration change in one place, not a change to every application.
