# Decisions

Each record states the context, the decision, what it costs, what was considered instead, and how the choice would be explained to a customer. A record is changed by a new record that supersedes it, not by editing history.

| # | Decision | Status |
|---|---|---|
| 1 | [Argo CD ApplicationSets keyed on the cluster Secret](0001-gitops-with-applicationsets.md) | proposed |
| 2 | [Karpenter on a small system node group, not EKS Auto Mode](0002-karpenter-not-auto-mode.md) | proposed |
| 3 | [EKS Pod Identity and access entries; no IRSA, no aws-auth](0003-pod-identity-and-access-entries.md) | proposed |
| 4 | [Gateway API, implemented by Envoy Gateway](0004-gateway-api-with-envoy-gateway.md) | proposed |
| 5 | [Admission policies the API server enforces itself](0005-admission-enforced-by-the-api-server.md) | proposed |
| 6 | [Every image by digest, every pin watched](0006-images-by-digest-pins-watched.md) | proposed |
| 7 | [Velero file-system backup on kind and on EKS](0007-velero-file-system-backup.md) | proposed |
| 8 | [Traces become span metrics; no tracing backend yet](0008-traces-as-span-metrics.md) | proposed |
| 9 | [kind is the daily proof; EKS is validated by hand before releases](0009-kind-daily-eks-by-hand.md) | proposed |
| 10 | [AWS validation runs: guards and cost reporting](0010-aws-validation-runs.md) | proposed, design only |
| 11 | [Cost defaults: one NAT gateway, Graviton, standard support only](0011-cost-defaults.md) | proposed |
| 12 | [Tenants: one directory each, one project each](0012-tenants-one-directory-each.md) | proposed |
| 13 | [Service level objectives that are proven to page](0013-slos-proven-to-page.md) | proposed |
