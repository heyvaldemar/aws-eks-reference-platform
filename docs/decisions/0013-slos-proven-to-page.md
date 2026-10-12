# 13. Service level objectives that are proven to page

- Status: proposed
- Date: 2026-10-12

## Context

Dashboards and alerts are easy to add and hard to trust. An alert rule with a wrong threshold or a typo in a label stays green for ever, and nobody finds out until the outage it was meant to announce.

## Decision

- The demo tenant owns its SLOs, next to its code (`apps/demo/base/slo.yaml`): 99.5% of requests without a 5xx over 30 days, and 99% of requests within 500 ms. Health and readiness probes are excluded from both.
- Alerts use the multi-window, multi-burn-rate method of the Google SRE workbook: page at 14.4 times the budget rate over an hour, confirmed over five minutes; open a ticket at 6 times over six hours, confirmed over thirty minutes.
- One set of recording rules feeds both the alerts and a Grafana dashboard, so what pages and what is shown are the same numbers.
- Three layers of proof: `promtool test rules` with synthetic series (a 50% error rate pages and opens a ticket; a 0.1% error rate does neither; probes do not dilute the ratio), a `validate.sh` check with planted violations (a threshold that can no longer fire, a rule that is not PromQL), and an e2e step that makes the running frontend fail and requires the page to fire within eight minutes.

## Consequences

- An alert in this repository has been seen to fire, in a test and in a cluster, before anyone relies on it.
- kind keeps a day of metrics, so the 30-day objective is evaluated over the windows that exist; on EKS Prometheus keeps fifteen days, and a month needs long-term storage (Thanos, Mimir or a managed service), which is not part of this platform yet.
- Alertmanager runs on EKS only and routes nowhere until a team connects it to its pager.
- The objective counts what the service says with its status code. podinfo, the demo's stand-in, reports handler errors with HTTP 200 and the real code in the body (`{"code": 500, "message": "reading file failed"}`), so those errors count as good requests. The SLO step passes because it fails requests through `/status/500`, which returns a real 500. A service measured this way has to return the status it means.

## Alternatives

- **Threshold alerts on error count or latency.** Simple, and either noisy at low traffic or late at high traffic; they say nothing about how much budget is left.
- **An SLO generator (Sloth, Pyrra).** Generates the same rules from a short spec; one more controller for one service. Worth adopting once several tenants define SLOs.

## How to explain this to a customer

Each service states how reliable it promises to be, and the platform alerts when that promise is being used up fast, not on every blip. Before trusting those alerts we prove them: an automated test feeds them a simulated outage and a normal day, and in the test cluster we break the service on purpose and wait for the alert to fire. You get alerts you have seen work, not alerts you hope work.
