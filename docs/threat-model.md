# Threat model

What this platform defends against, the control for each threat, and the check that proves the control holds. A control without a check is listed as a residual risk, not as a control.

"Daily" means the kind e2e run (`tests/e2e/run.sh`); "every change" means the static checks and their planted violations (`scripts/validate.sh`, `tests/static/plants.tsv`) or the Terraform tests (`terraform/tests/`). The EKS rows are proven against a mocked plan on every change; the weekly run on AWS (`tests/eks/run.sh`, ADR 10) adds a real account for what it checks: admission, IMDSv2, the certificate issued by DNS-01 and served by the load balancer, Karpenter and Velero. A row with only the mocked plan behind it says so.

## What is protected, and from whom

| Asset | Why it matters |
|---|---|
| The cluster's API and its admission control | whoever controls admission controls everything that runs |
| Tenant workloads and their data | the reason the platform exists |
| Secrets in the store | one secret read across a tenant boundary is a breach |
| Backups | the last line after every other control has failed |
| The GitOps control plane (Argo CD, this repository) | it has cluster-wide rights and applies whatever the pinned commit says |
| The AWS account (EKS path) | IAM, KMS keys, the network, the bill |

The actors the controls are designed against: a tenant team that makes a mistake or tries to widen its own rights; a compromised workload inside a tenant namespace; a dependency that changes under a tag or a version range; an operator who scales a controller to zero during an incident. A malicious platform administrator with merge rights to this repository is out of scope: they own the controls.

## Trust boundaries

1. **Git to cluster.** Argo CD applies this repository at one pinned commit (`platform_revision` on the cluster Secret). A branch push changes nothing until the cluster is moved to a new commit.
2. **Platform to tenant.** A tenant owns `apps/<team>/` and nothing else. The platform owns the tenant's namespace, its labels, its quota and its Argo CD project (`platform/tenant`).
3. **Tenant to tenant.** Network policy, the secret store's namespace conditions, and one destination per project.
4. **Pod to node and to cloud.** Pod Security `restricted`, IMDSv2 with a hop limit of 1, Pod Identity scoped to one namespace and service account.

## Threats, controls and evidence

### Tenant boundary

| Threat | Control | Evidence | When |
|---|---|---|---|
| A tenant's manifests create a cluster-scoped object (a ClusterRoleBinding, a Namespace with its own labels) | the tenant's AppProject allows no cluster-scoped kind; the namespace is created by `platform/tenant` | `check-argocd.py` on the rendered tenant; plant: a tenant that writes its own Namespace | every change |
| A tenant writes into another tenant's namespace | the project's only destination is the tenant's namespace | e2e 5b: team-b's manifests pointed at `demo` are refused by Argo CD; plant: a kustomization that sets another namespace | daily, every change |
| A tenant binds itself `admin` in its namespace and edits the quota through the API | the project allows only listed kinds (`allowedKinds`), and Role and RoleBinding are not on the list; the tenant's syncs run as `tenant-<team>-deployer` (Argo CD sync impersonation, enforced), whose Role grants the same kinds in the tenant's namespace and nothing else, so the API server refuses what the project refuses | e2e 5b: an Application of team-b's syncing a RoleBinding to `admin` is refused, and `kubectl auth can-i` shows team-b's sync account may write Deployments in team-b but not RoleBindings, Secrets, the quota, or anything in `demo`; plants: the RoleBinding in a tenant, RoleBinding added to the allow-list, a wildcard in the deployer Role, a tenant project that syncs as the controller, impersonation switched off | daily, every change |
| A tenant Application is aimed at a platform namespace | same single destination | e2e 5b: an Application of team-b's aimed at `kube-system` is refused | daily |
| A directory named `kyverno` or `kube-system` takes a platform namespace and gets a project for it | the tenant chart refuses reserved names, `kube-*` and `tenant-*`; its project is never created, so the tenant's Application is not either | `check-argocd.py` runs the chart against every reserved name and fails when a platform namespace or Application is missing from the list; two plants | every change |
| A tenant drops Pod Security on its namespace | only the platform writes the Namespace; a native admission policy refuses a tenant namespace without `restricted` | e2e step 2 reads the label; plant manifest `tenant-without-pss` refused | daily |
| A tenant reads another tenant's secret through the platform store | `ClusterSecretStore` conditions list the namespaces that may use it, in a platform file | e2e 5b: team-b's ExternalSecret for `demo/message` is not Ready and no Secret appears | daily |
| A tenant runs a Gateway of its own, with its own load balancer | Gateway is not on the allow-list; the quota allows no LoadBalancer or NodePort Service | allow-list check in `check-argocd.py`; e2e 5b reads the quota | every change, daily |
| A noisy tenant starves the others | ResourceQuota per tenant namespace (CPU and memory requests, memory limits, pods, volumes, storage) | e2e 5b reads the quota from the namespace | daily |

### Admission and workloads

| Threat | Control | Evidence | When |
|---|---|---|---|
| An image changes under its tag | admission refuses any container image without a digest; every image pin in the repository is a digest | e2e step 1 reads every running pod; plant manifest `tag-only-image` refused; `check-images.py` on the rendered manifests | daily, every change |
| A privileged pod, or one with host access | Pod Security `restricted` on every tenant namespace | plant manifest `privileged` refused by Pod Security | daily |
| A workload without limits or probes | native admission policies (`require-requests-limits`, `require-probes`) | plant manifests refused, each by the policy named in it; a compliant control must be admitted | daily |
| Admission opens when Kyverno is scaled to zero (Kyverno deletes its webhooks on the way down) | policies compiled into native ValidatingAdmissionPolicies, enforced by the API server itself | e2e 4b: Kyverno at zero replicas, every plant still refused; static check that every policy has a native counterpart; plant | daily, every change |
| A compromised pod moves sideways inside the cluster | Kyverno generates a default-deny NetworkPolicy in every tenant namespace; teams open paths one at a time | e2e step 5: three connections that must fail, and a control that must succeed; Kyverno puts a deleted default-deny back (hands-on) | daily, weekly |
| A compromised backend sends data to the internet | the demo's pods may reach DNS and the OpenTelemetry Collector and nothing else; the generated default-deny covers the rest | e2e step 5: the backend cannot reach the internet | daily |

### Supply chain and GitOps

| Threat | Control | Evidence | When |
|---|---|---|---|
| A push to a branch changes every cluster | every Git source and generator reads the cluster's pinned commit | `check-argocd.py`; plants: a source on a branch, a generator on `HEAD` | every change |
| A chart moves under a version range | exact chart versions only | `check-argocd.py`; plant: a version range | every change |
| A pin falls behind its upstream security fixes | weekly freshness check on charts, images, tools, providers and the Kubernetes version | `check-freshness.py` | weekly |
| A manifest uses an API the cluster no longer serves | kubeconform against the installed CRDs, pluto for removed APIs | plants: a misspelled field, an API removed in 1.25 | every change |

### Data and recovery

| Threat | Control | Evidence | When |
|---|---|---|---|
| A backup that copied nothing, and a restore that reports `Completed` over an empty disk | volumes Velero can read (`kind-local`, `defaultVolumeType: local`); the drill counts PodVolumeBackups and reads data back | e2e step 7: back up, delete the namespace and its volume, restore, read the marker written before the backup | daily |
| A restore procedure nobody has run | the hands-on guide's restore exercise runs as written | `hands-on.yml` | weekly |
| Backups readable, deletable or tampered with in S3 (EKS) | bucket never public, versioned, KMS-encrypted, TLS only | `terraform test`, each assertion with a planted violation | every change, mocked plan |

### Cluster and cloud (EKS path, mocked plan)

| Threat | Control | Evidence | When |
|---|---|---|---|
| Whoever created the cluster stays its silent admin | access entries only (`authentication_mode = "API"`), no implicit creator admin | `terraform test` with planted violations | every change |
| The API endpoint is open to the internet | public endpoint restricted to listed CIDRs; nodes reach the API privately | `terraform test` | every change |
| Secrets readable from etcd | KMS envelope encryption, keys rotated | `terraform test` | every change |
| A pod steals the node's instance credentials | IMDSv2 only, hop limit 1 | `terraform test` | every change |
| A controller's cloud role is usable from other pods | Pod Identity bound to one namespace and service account; External Secrets may read only under `demo/`; cert-manager may only write ACME challenge records | `terraform test` | every change |
| Shell access to nodes | no SSH; SSM | `terraform test` | every change |
| Nobody can tell who changed what | the control plane audit log is on; flow logs record accepted and rejected traffic; log groups have a retention | `terraform test` | every change |

## Residual risks

What the platform does not cover today, said plainly so nobody assumes it does.

- **Platform syncs run with cluster-wide rights.** Tenant syncs run as their own deployer accounts, but the platform's Applications sync as the controller's service account, because the platform installs cluster-scoped add-ons. Whoever can push to this repository controls the platform; who has write access to it is the control there, not Argo CD.
- **Image digests pin bytes, not provenance.** Nothing on this platform verifies a signature or an SBOM at admission. [kubernetes-supply-chain-admission](https://github.com/heyvaldemar/kubernetes-supply-chain-admission) does, with the same Kyverno: one signer, provenance, an SBOM and a recent scan, and a native registry allowlist under it for when Kyverno is down.
- **No runtime detection.** Nothing watches system calls or process trees inside a running container (Falco, Tetragon). A compromised workload that stays inside its namespace and its network policy is not detected.
- **No encryption between pods.** Traffic inside the cluster is plain; TLS ends at the Gateway. A service mesh or the VPC CNI's encryption would change that.
- **kind has no audit log and no KMS.** The daily proof runs on kind; the controls that only exist in AWS are proven against a mocked plan, not a live account.
- **The demo's SLO trusts status codes.** podinfo reports handler errors with HTTP 200 and the code in the body, so those errors count as good requests (ADR 13).
- **Grafana and Argo CD are reached by port-forward**, with an admin password from the cluster. There is no SSO in front of either.

## How to explain this to a customer

Every protection on this platform comes with a test that tries to break it, and the tests run every day. A team cannot give itself more rights, reach another team's space or data, or switch the rules off, and the platform proves each of those by attempting it. The page also lists what is not covered yet, such as signature checks on images and runtime threat detection, so the decisions about those are made knowingly rather than assumed.
