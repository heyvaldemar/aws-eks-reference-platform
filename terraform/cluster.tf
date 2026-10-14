data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# The IAM principal behind the caller: for an assumed role, the role's ARN
# rather than the session's, which is what an access entry needs.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  admins     = distinct(concat([data.aws_iam_session_context.current.issuer_arn], var.admin_principal_arns))
}

# --- keys ---------------------------------------------------------------------

resource "aws_kms_key" "eks" {
  description             = "${var.cluster_name}: envelope encryption of Kubernetes Secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# One key for the log groups. CloudWatch Logs has to be allowed to use it
# explicitly; the account root alone is not enough.
resource "aws_kms_key" "logs" {
  description             = "${var.cluster_name}: CloudWatch log groups"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministers"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogsUses"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.region}.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
        Condition = {
          ArnLike = { "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:*" }
        }
      },
    ]
  })
}

# --- control plane -------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name                 = "${var.cluster_name}-cluster"
  permissions_boundary = var.iam_permissions_boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_cloudwatch_log_group" "cluster" {
  # The name EKS writes to; created here so retention and encryption are ours.
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # Who may use the cluster is decided by access entries in this
  # configuration, not by an aws-auth ConfigMap and not by "whoever created it".
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Standard support only. When a version leaves standard support EKS moves a
  # cluster to extended support automatically, at six times the hourly price;
  # STANDARD makes it upgrade instead, which is the bill nobody budgeted for
  # turned into a change somebody has to plan.
  upgrade_policy {
    support_type = "STANDARD"
  }

  # The add-ons below are installed as managed add-ons, at versions EKS
  # supports for this Kubernetes version; nothing self-managed underneath.
  bootstrap_self_managed_addons = false

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# Karpenter finds the security group for the nodes it launches by this tag.
resource "aws_ec2_tag" "cluster_security_group_discovery" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# --- who can use it -----------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each      = toset(local.admins)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = toset(local.admins)
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
