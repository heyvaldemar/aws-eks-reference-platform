# EKS managed add-ons at the version EKS marks as the default for this
# Kubernetes version. A version is not pinned here on purpose: EKS supports a
# narrow range per cluster version, and a stale pin is what turns a control
# plane upgrade into a failed one. `terraform plan` shows when the default
# moves.

# Needed before any node can become Ready.
resource "aws_eks_addon" "before_nodes" {
  for_each = {
    vpc-cni = {
      # The VPC CNI enforces Kubernetes NetworkPolicies itself (eBPF); the
      # demo tenant's default-deny relies on it. Prefix delegation gives each
      # node far more pod IPs from the same subnet.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
        }
      })
      service_account = "aws-node"
      role_arn        = aws_iam_role.vpc_cni.arn
    }
    eks-pod-identity-agent = {
      configuration_values = null
      service_account      = null
      role_arn             = null
    }
    kube-proxy = {
      configuration_values = null
      service_account      = null
      role_arn             = null
    }
  }

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  dynamic "pod_identity_association" {
    for_each = each.value.role_arn == null ? [] : [each.value]
    content {
      role_arn        = pod_identity_association.value.role_arn
      service_account = pod_identity_association.value.service_account
    }
  }
}

# Need schedulable nodes to become active.
resource "aws_eks_addon" "after_nodes" {
  for_each = {
    coredns            = { service_account = null, role_arn = null }
    metrics-server     = { service_account = null, role_arn = null }
    aws-ebs-csi-driver = { service_account = "ebs-csi-controller-sa", role_arn = aws_iam_role.ebs_csi.arn }
  }

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  dynamic "pod_identity_association" {
    for_each = each.value.role_arn == null ? [] : [each.value]
    content {
      role_arn        = pod_identity_association.value.role_arn
      service_account = pod_identity_association.value.service_account
    }
  }

  depends_on = [aws_eks_node_group.system]
}

# --- the add-ons' own AWS permissions, through Pod Identity ---------------------

locals {
  pod_identity_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role" "vpc_cni" {
  name               = "${var.cluster_name}-vpc-cni"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = local.pod_identity_trust
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
