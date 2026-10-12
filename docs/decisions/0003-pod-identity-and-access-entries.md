# 3. EKS Pod Identity and access entries; no IRSA, no aws-auth

- Status: proposed
- Date: 2026-10-11

## Context

Six controllers need AWS permissions (Karpenter, the load balancer controller, ExternalDNS, cert-manager, External Secrets, Velero), plus the VPC CNI and the EBS driver. People need access to the cluster. EKS supports two generations of each: IRSA and Pod Identity for workloads, the `aws-auth` ConfigMap and access entries for people.

## Decision

- **Workloads:** EKS Pod Identity. Terraform creates one IAM role per controller, trusted by `pods.eks.amazonaws.com`, and associates it with exactly one namespace and service account. The VPC CNI and EBS driver get theirs through their managed add-on's `pod_identity_association`; the node role has no CNI policy.
- **People:** access entries only (`authentication_mode = "API"`), with `bootstrap_cluster_creator_admin_permissions = false`. The role running Terraform and any listed in `admin_principal_arns` get `AmazonEKSClusterAdminPolicy`; the access entry uses the IAM role, not its STS session ARN.
- Nodes keep IMDSv2 with a hop limit of one, so a pod cannot borrow the node's role.

## Consequences

- No OIDC provider, and no role ARN annotation on any service account: the Kubernetes manifests are identical in every account.
- Who has which AWS permission, and who can use the cluster, is all in Terraform. `terraform test` asserts each controller's namespace and service account, so a rename on one side fails CI instead of failing at runtime with no credentials.
- Pod Identity needs its agent add-on on every node and an SDK recent enough to use it; every controller here supports it.
- Cross-account access is less direct than with IRSA (role chaining). Not needed here.

## Alternatives

- **IRSA.** Works everywhere, including outside EKS, but needs an OIDC provider per cluster and an account-specific annotation in every manifest.
- **`aws-auth` ConfigMap.** Deprecated in favour of access entries; one bad edit locks everyone out, and its contents are invisible to IAM.

## How to explain this to a customer

Each component gets exactly the AWS permissions it needs, tied to that one component by name, and nothing in your Kubernetes files changes between accounts. Cluster access is granted through IAM like everything else in AWS, so it shows up in the same reviews and audit trails, and nobody holds admin just because they happened to create the cluster.
