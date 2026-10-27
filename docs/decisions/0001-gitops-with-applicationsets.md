# 1. Argo CD ApplicationSets keyed on the cluster Secret

- Status: accepted
- Date: 2026-10-11

## Context

The platform runs the same add-ons on two kinds of cluster (kind every day, EKS before releases) and is meant to run on more (GKE and AKS share this core next). Most of the configuration is identical; a few values differ per cluster: the domain, the region, a bucket name, which add-ons apply at all. Whatever installs the platform has to answer three questions: what goes on a cluster, with which values, and at which version.

## Decision

Argo CD installs everything after a one-time bootstrap. Each cluster is one Argo CD cluster Secret:

- **labels** decide which add-ons it gets (`enable_karpenter: "true"`);
- **annotations** carry what differs (`domain`, `aws_region`, `velero_bucket`) and the commit of this repository the cluster runs (`platform_revision`).

Each add-on is one ApplicationSet with a cluster generator. It renders an Application per matching cluster from a pinned chart version and three values files read at `platform_revision`. Terraform's outputs become the annotations on EKS; `platform/clusters/kind.env` holds them for kind. Argo CD manages its own release after the bootstrap installs it.

## Consequences

- A cluster's whole configuration is one commit hash plus a short list of labels. Moving a cluster to a release is one change to one Secret.
- Adding a cluster type is a new `.env` file and, where it differs, a values file. No add-on definition changes.
- Nothing follows a branch: chart versions are exact and Git sources take the cluster's commit; `scripts/check-argocd.py` fails the build otherwise.
- Templating lives in two places (Go templates in ApplicationSets, Helm values), which is more to read than one Helm umbrella chart. `scripts/render.py` renders it the way Argo CD would, so CI checks the result, not the templates.
- Argo CD reads the remote repository, not the working tree: a local change has to be pushed before a cluster can run it.

## Alternatives

- **One Helm umbrella chart.** Simple to install, but one release for everything: one failing sub-chart blocks all of them, and per-cluster differences turn into a values file per cluster.
- **Terraform `helm_release` for the add-ons.** Couples cluster lifecycle and add-on lifecycle in one state and one plan, and leaves nothing reconciling drift between applies.
- **Flux.** A sound choice with the same model; Argo CD was picked for its ApplicationSet cluster generator and because its UI is what most platform teams already operate.

## Revisited, 2026-10-27

Argo CD still manages its own release, with one exception at an upgrade. It applies its new release only by syncing it, alongside every other Application the new revision moves, so the controller that has to get through that is the old one. Moving v1.2.0 to nine new charts, v1.2.0's controller was OOMKilled at its 1Gi limit nine times and never applied its own update ([kind e2e run 40550141772](https://github.com/heyvaldemar/aws-eks-reference-platform/actions/runs/40550141772)). The limit is now 2Gi, and `bootstrap/bootstrap.sh`, re-run to move a cluster to a revision, first gives the running controller the memory limit that revision sets in `platform/values/argo-cd/common.yaml`. When the controller already has it, nothing restarts. Nothing else is installed twice, and Argo CD's next sync of itself writes the same value.

## How to explain this to a customer

Every cluster you run is described by two things: which version of the platform it runs, and a short list of switches for what it needs. Upgrading a cluster, or rolling it back, is changing that version number in one place, and Argo CD makes the cluster match it, including putting back anything someone changed by hand. You get a record of what every cluster runs, and a new cluster is a copy of an existing description, not a project.
