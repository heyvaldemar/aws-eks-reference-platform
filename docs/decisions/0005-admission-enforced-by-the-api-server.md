# 5. Admission policies the API server enforces itself

- Status: proposed
- Date: 2026-10-11

## Context

Tenant workloads have to meet a floor. Images are referenced by digest and containers carry requests and a memory limit. Long-running workloads have probes, and tenant namespaces enforce the restricted Pod Security Standard. Kyverno 1.19 has two policy APIs: the older `kyverno.io` ClusterPolicy, which its release notes now mark deprecated, and CEL-based `policies.kyverno.io/v1` policies, which can also be compiled into native Kubernetes ValidatingAdmissionPolicies.

While this repository was being built, a test that scaled Kyverno's admission controller to zero showed that Kyverno removes its own webhooks when it stops. Every webhook-enforced policy then admitted everything: a pod with no digest and no limits was accepted.

## Decision

- Validation is written as Kyverno `ValidatingPolicy` with `autogen.validatingAdmissionPolicy.enabled: true`. Kyverno compiles each into a ValidatingAdmissionPolicy and binding; the API server evaluates them in process, with no webhook call.
- Each policy handles Pods and the controllers that make them in one CEL expression (a `podSpec` variable), because Kyverno's own pod-controller autogen rules out the native form.
- Generation (a default-deny NetworkPolicy in every tenant namespace) stays a Kyverno `GeneratingPolicy`; Kubernetes has no native equivalent.
- `scripts/check-policy-tests.py` fails the build if a ValidatingPolicy is not compiled natively or has no test that shows it a violation. The e2e suite scales Kyverno to zero and requires every planted violation to stay refused.

## Consequences

- A Kyverno outage or crash loop does not open admission.
- The policies use only standard CEL, so they stay portable to clusters without Kyverno: the generated ValidatingAdmissionPolicies are plain Kubernetes objects.
- A namespace created while Kyverno is down gets its default-deny when Kyverno returns (`generateExisting`), not before. That window is the cost of keeping generation in Kyverno.
- Messages from the API server name the generated policy (`vpol-require-image-digest`), not the Kyverno one. The hands-on guide shows how to trace one to the other.

## Alternatives

- **Kyverno ClusterPolicy.** Deprecated as of 1.19, and webhook-only.
- **OPA Gatekeeper.** Rego is a second language for the team to own, and enforcement is a webhook with the same failure mode.
- **Hand-written ValidatingAdmissionPolicies.** Native from the start, but with nothing to generate the default-deny and no image verification later, which flagship #3 needs from Kyverno.

## How to explain this to a customer

The rules every workload has to follow are enforced by Kubernetes itself, not by an add-on that can be down. We proved it by switching the policy engine off and trying to deploy things that break the rules: they were still refused. The engine still writes the rules and sets up the default network isolation for each new team.
