# 9. kind is the daily proof; EKS is validated by hand before releases

- Status: accepted
- Date: 2026-10-11

## Context

The repository's claims have to be true, and checkable by anyone. Running EKS on every change would cost money continuously and would need cloud credentials in CI. Running nothing real would leave the platform untested.

## Decision

- Every change and every day: a kind cluster on a GitHub runner, the whole platform installed by Argo CD from the commit under test, and the e2e suite against it. A second job installs the previous release, writes a marker, moves the cluster to the commit, and requires the marker and every check.
- The EKS Terraform is checked on every change with `terraform fmt`, `validate`, tflint with the AWS ruleset, and `terraform test` on a plan against a mocked provider, with 24 planted violations that must each fail the test. It is not applied in CI.
- A real EKS run is manual, before a release, only with the maintainer's explicit go-ahead, under the guards in ADR 10.
- The README says "tested daily on kind". It will say "the EKS path is validated manually before releases" only after that has happened, with the date and commit.

## Consequences

- Zero cloud cost for the daily proof, and no AWS credentials in CI.
- Everything AWS-specific (Karpenter, the NLB, Pod Identity, Route 53, Let's Encrypt) is checked statically until the first manual run. A wrong IAM action or a controller value only AWS validates would surface there, not on a pull request.
- The two environments share every add-on, policy and test. The differences are listed in the README's table, and each one is a value, not a code path.

## Alternatives

- **EKS on a schedule.** The strongest proof, at a standing cost and with cloud credentials reachable from CI. Rejected for now; ADR 10 describes how it would be made safe if wanted.
- **LocalStack for the AWS parts.** Emulates APIs, not EKS behaviour; it would add confidence in the wrong places.

## Revisited, 2026-10-14

The EKS run is now weekly as well as by hand before a release ([ADR 10](0010-aws-validation-runs.md), "Weekly"). The daily proof stays on kind. The README will say the EKS path is validated weekly only once scheduled runs have passed, with their dates and commits. The first manual run passed on 2026-10-15 ([ADR 10](0010-aws-validation-runs.md), "Validated").

## How to explain this to a customer

Everything you see claimed here is checked automatically every day on a real Kubernetes cluster, at no cloud cost, and the checks are designed so that each one has been seen to fail. The AWS-specific parts are checked for their security settings on every change, and run for real on AWS by hand before a release, under a strict spending limit. We say which is which, and we do not claim the second until it has happened.
