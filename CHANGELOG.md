# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- `bootstrap-aws`: the budget counted credits, as AWS Budgets does by default, so in an account running on promotional credits the $5 and $10 alerts and the $15 kill switch would never fire, and a run left running would spend the credits instead. It now measures usage before credits (`cost_types.include_credit = false`), with a test and a planted violation. The sweeper's daily table leaves credits and refunds out for the same reason.

### Changed

- The EKS validation run is weekly as well as by hand (ADR 9 and ADR 10, revisited): every Wednesday, after Monday's Dependabot updates have merged, and only while the repository variable `AWS_VALIDATION_ENABLED` is `true`, so it stops without a commit. The bootstrap's alerts move to $10 and $20 and its kill-switch to $30, the ceiling for a month of weekly runs.
- ADR 10 and the bootstrap README allow a member account in the maintainer's own AWS Organization, and say why an account that holds other work is the wrong place: the workflow roles can delete what they did not make.
- The README points at [kubernetes-postgres-recovery](https://github.com/heyvaldemar/kubernetes-postgres-recovery), the database a tenant would run here, with the point-in-time recovery that Velero's volume snapshots cannot give it.

### Added

- Live status: every e2e run uploads its checks and measurements (`E2E_RESULTS`), and `.github/workflows/status.yml` rewrites the `status` branch after each run with the last 30 days on main: green days, the streak, the latest checks (`scripts/status.py`). The README's second row of badges reads it.

## [1.1.0] - 2026-10-13

### Added

- `tools/kubectl-tenant`, onboarding as a command. `kubectl tenant new <team>` writes `apps/<team>` from the template and refuses the names the tenant chart refuses, read from `platform/tenant/values.yaml` so the two lists cannot drift apart. `kubectl tenant check <team>` reports from the files alone what admission would refuse: an image without a digest, missing requests, no memory limit, missing probes, a privileged container, the host network. Its tests rebuild `apps/team-b`, made by hand, and fail if the command's result differs.
- `terraform/bootstrap-aws`, the account ADR 10 asks for: GitHub OIDC roles trusted per environment, a creation role held by guardrails and by a permissions boundary that every role it creates must carry, a sweep role that reads, deletes and rewrites a run's state but creates nothing, a versioned state bucket, budget alerts at $5 and $10, and a kill switch at $15 that attaches deny-all to the creation role. Its tests run against a mocked provider, and each guardrail is shown a planted violation it must catch (10 plants).
- The EKS validation run, built and not yet applied (`.github/workflows/eks-validation.yml`). It is dispatched by hand with `confirm: SPEND` from `main` only, keeps one state per run, and runs seven checks against the live cluster (`tests/eks/run.sh`): every Application synced and healthy, admission refusing its plants, IMDSv2 with a hop limit of 1 on the nodes, the ExternalDNS record, a Let's Encrypt certificate served by the NLB, Karpenter's NodePool and EC2NodeClass ready, and a Velero backup with objects in the bucket. Teardown is a separate job that runs whatever the first one did, then a residue check fails on anything the run left behind, and a cost report prices the run's resource-hours. A daily sweeper (`eks-sweeper.yml`) deletes what a broken run left and stays off until the repository variable `AWS_VALIDATION_ENABLED` is `true`.
- Terraform: `zone_id` uses an existing, delegated Route 53 zone instead of creating one, and refuses a zone whose name is not the domain; `iam_permissions_boundary` sets a permissions boundary on all seven IAM roles the module creates.
- `docs/engagement/`: an executive summary, discovery questions, a success plan whose eleven criteria map to e2e steps, an adoption plan from Docker Compose to a tenant, sizing, and handover.
- CodeQL (security-extended) for Python, Go and the workflows, on every push and weekly.
- The OpenSSF Best Practices badge, passing, and a README section on where a bug, a question or a change goes.

### Changed

- The README lists the known limitations in one place.
- ADR 5 cites [kyverno/kyverno#6554](https://github.com/kyverno/kyverno/issues/6554): Kyverno deletes its own webhook configurations when its admission controller scales to zero, by design since 1.9.
- CI's one Python package, PyYAML, is installed with `--require-hashes`.
- `scripts/diagnose.sh` prints the conditions of the object a waiting Argo CD sync waits on. Argo CD 3 keeps no per-resource health in the Application, so a timed-out run said only which object, never why.
- Charts: argo-cd 10.10.3, kube-prometheus-stack 92.3.1, opentelemetry-collector 0.176.0. The rendered manifests differ only in the chart version labels.

### Security

- `bootstrap-aws`, before it was ever released: the creation role could create a role without the guardrails, or rewrite the guardrails policy, and act through either. Every role it creates must now carry the permissions boundary, the bootstrap's own roles and policies are out of its reach, and the roles it may touch are limited to the run's prefix. Found in review before any account was created. What it still does not stop is written down in `terraform/bootstrap-aws/README.md`.

## [1.0.1] - 2026-10-13

### Fixed

- `bootstrap.sh` stores `PLATFORM_REPO_TOKEN` without a trailing newline. It was fed through a here-string, which appends one, and Argo CD sent the token as stored when it listed the remote's refs, so an Application pinned to a tag or a branch failed with "Invalid username or token" whenever the token was set, on a public repository as on a private one. A commit SHA needs no listing, which is why the e2e run, pinned to a commit, never saw it; the upgrade job, the first to read a tag, did.

### Added

- e2e step 8: Argo CD resolves the latest release tag with the credential the cluster holds.

### Changed

- The README and the threat model point at the two repositories next to the platform: the agent sandbox, and supply chain admission, which closes the threat model's open risk on unsigned images. ADR 3 says what the trust policy names rather than what the role is trusted by.

## [1.0.0] - 2026-10-12

### Added

- The platform as Argo CD ApplicationSets keyed on the cluster Secret: Envoy Gateway, cert-manager, External Secrets, Kyverno, kube-prometheus-stack, the OpenTelemetry Collector and Velero on every cluster; Karpenter, the AWS Load Balancer Controller and ExternalDNS on EKS.
- Kyverno CEL policies compiled into native ValidatingAdmissionPolicies: images by digest, requests and memory limits, probes, restricted Pod Security for tenants; a generated default-deny NetworkPolicy per tenant namespace.
- Tenants: one directory under `apps/` per team. The platform creates the namespace, its labels and quota, and an Argo CD project whose only destination is that namespace and which allows only the kinds a service needs, no RBAC among them. Every sync runs as the account its project names (Argo CD sync impersonation, enforced); a tenant's runs as a deployer whose Role grants the same kinds in its own namespace. The team's directory holds only what runs inside it.
- An SLO for the demo (availability and latency) with multi-window burn-rate alerts, unit-tested with promtool and shown to page in the kind e2e run.
- Terraform for EKS 1.37: VPC, cluster with access entries and KMS-encrypted Secrets, Graviton system node group, managed add-ons, Pod Identity for six controllers, Karpenter's AWS side, the Velero bucket and the Route 53 zone. Tested against a mocked provider; not yet applied to a real account.
- The kind e2e suite, run on every change and daily, and its upgrade job from the previous release.
- Static checks on the rendered manifests and the Terraform, each shown its planted violation.
- Runbooks for upgrade, rollback, restore and incident, and a hands-on guide whose three exercises run as written every week.
- Thirteen decision records, each ending with how the choice would be explained to a customer; a threat model with the check behind every control; a Well-Architected review with the evidence and the gaps.

[Unreleased]: https://github.com/heyvaldemar/aws-eks-reference-platform/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/heyvaldemar/aws-eks-reference-platform/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/heyvaldemar/aws-eks-reference-platform/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/heyvaldemar/aws-eks-reference-platform/releases/tag/v1.0.0
