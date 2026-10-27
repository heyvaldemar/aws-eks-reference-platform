# Upgrade

Two kinds of upgrade happen here, and they go through the same gate.

## A component (chart, image, tool)

The weekly freshness job (`scripts/check-freshness.py`) reports a pin that fell behind. To move it:

1. Change the chart's `targetRevision` in `platform/appsets/<component>.yaml`.
2. See which images the new chart version picks by itself:

   ```bash
   RENDER_CHART_DEFAULT_IMAGES=1 python3 scripts/render.py kind out/defaults
   grep -h 'image:' out/defaults/<component>.yaml | sort -u
   ```

3. Pin each of those in `platform/values/<component>/images.yaml`, with its digest:

   ```bash
   docker buildx imagetools inspect <repository>:<tag> | awk '/^Digest:/{print $2}'
   ```

4. Read the component's own upgrade notes for the versions in between. CRD changes and removed values are the usual breakage; `make check` catches a removed value only if the chart validates its values.
5. Open a pull request. Verification and kind e2e must pass, including the upgrade job that installs the previous release and moves it to your commit.
6. Cut the release as `CHANGELOG.md` describes, with an Upgrading section if anything in it needs a person.

A cluster picks up the release when it is moved to it:

```bash
PLATFORM_REVISION=v1.1.0 ./bootstrap/bootstrap.sh kind   # or eks
make wait
```

`bootstrap.sh` does not reinstall Argo CD on a re-run. It updates the cluster Secret to the new revision; once the argo-cd Application names it, it gives the running application controller the memory limit and `GOMEMLIMIT` that revision sets, because that controller syncs everything the revision moves before it gets to its own update ([ADR 1](../decisions/0001-gitops-with-applicationsets.md), revisited 2026-10-27). Then it moves the root Application to the new revision, and Argo CD does the rest, Argo CD itself included.

## Kubernetes

1. Read the [EKS release notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) for the target minor, and check every add-on and chart supports it.
2. Change the version in six places together: `KUBE_VERSION` in `scripts/validate.sh` and in `scripts/render.py`, the node image in `kind/cluster.yaml` (from the kind release notes, with its digest), `kubectl` in `tools.lock`, `kubernetes_version` in `terraform/variables.tf`, and the cluster version the posture test asserts in `terraform/tests/posture.tftest.hcl`.
3. `make check`: kubeconform validates against the new version's schemas and pluto reports APIs it removed.
4. kind e2e proves the platform on the new version. For EKS, the control plane moves one minor at a time (`terraform apply` with the next minor), then the managed node group, then Karpenter's nodes roll on their own as `expireAfter` and drift replace them.

## Terraform state for a shared cluster

Local state is the default so a first `make eks-up` needs nothing beforehand. For a cluster more than one person touches, move it to S3 with native locking before anyone else applies:

```bash
terraform -chdir=terraform init -migrate-state \
  -backend-config="bucket=<state bucket>" -backend-config="key=aws-eks-reference-platform.tfstate" \
  -backend-config="region=<region>" -backend-config="use_lockfile=true"
```
