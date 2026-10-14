# AWS permissions for the platform's controllers, one IAM role each, bound to
# exactly one namespace and service account through EKS Pod Identity. No
# OIDC provider, no role ARN annotation on any service account, nothing in the
# Kubernetes manifests that changes between accounts.
#
# The namespace and service account names here are the ones the values files
# in platform/values/ set; a rename on one side without the other leaves the
# controller with no credentials, which is why tests/posture.tftest.hcl
# asserts them.

locals {
  controllers = {
    karpenter = {
      namespace       = "karpenter"
      service_account = "karpenter"
      policy = templatefile("${path.module}/policies/karpenter-controller.json.tftpl", {
        partition              = local.partition
        region                 = var.region
        account_id             = local.account_id
        cluster_name           = var.cluster_name
        node_role_arn          = aws_iam_role.karpenter_node.arn
        interruption_queue_arn = aws_sqs_queue.karpenter_interruption.arn
      })
    }
    aws-load-balancer-controller = {
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
      # Upstream's policy for this release, unchanged:
      # https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v3.6.0/docs/install/iam_policy.json
      policy = file("${path.module}/policies/aws-load-balancer-controller.json")
    }
    external-dns = {
      namespace       = "external-dns"
      service_account = "external-dns"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect   = "Allow"
            Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets", "route53:ListTagsForResources"]
            Resource = local.zone_arn
          },
          {
            Effect   = "Allow"
            Action   = ["route53:ListHostedZones"]
            Resource = "*"
          },
        ]
      })
    }
    cert-manager = {
      namespace       = "cert-manager"
      service_account = "cert-manager"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect   = "Allow"
            Action   = "route53:GetChange"
            Resource = "arn:${local.partition}:route53:::change/*"
          },
          {
            # Only the TXT records of an ACME DNS-01 challenge, only in this zone.
            Effect   = "Allow"
            Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
            Resource = local.zone_arn
            Condition = {
              "ForAllValues:StringEquals" = {
                "route53:ChangeResourceRecordSetsRecordTypes" = ["TXT"]
              }
              "ForAllValues:StringLike" = {
                "route53:ChangeResourceRecordSetsNormalizedRecordNames" = ["_acme-challenge.*"]
              }
            }
          },
          {
            Effect   = "Allow"
            Action   = "route53:ListHostedZonesByName"
            Resource = "*"
          },
        ]
      })
    }
    external-secrets = {
      namespace       = "external-secrets"
      service_account = "external-secrets"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            # Read, and only under the demo/ prefix; nothing else in the
            # account's Secrets Manager is visible to the cluster.
            Effect   = "Allow"
            Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
            Resource = "arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:demo/*"
          },
          {
            Effect   = "Allow"
            Action   = "kms:Decrypt"
            Resource = aws_kms_key.data.arn
          },
        ]
      })
    }
    velero = {
      namespace       = "velero"
      service_account = "velero"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect   = "Allow"
            Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
            Resource = "${aws_s3_bucket.velero.arn}/*"
          },
          {
            Effect   = "Allow"
            Action   = "s3:ListBucket"
            Resource = aws_s3_bucket.velero.arn
          },
          {
            Effect   = "Allow"
            Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
            Resource = aws_kms_key.data.arn
          },
        ]
      })
    }
  }
}

resource "aws_iam_role" "controller" {
  for_each             = local.controllers
  name                 = "${var.cluster_name}-${each.key}"
  permissions_boundary = var.iam_permissions_boundary
  assume_role_policy   = local.pod_identity_trust
}

resource "aws_iam_role_policy" "controller" {
  for_each = local.controllers
  name     = each.key
  role     = aws_iam_role.controller[each.key].id
  policy   = each.value.policy
}

resource "aws_eks_pod_identity_association" "controller" {
  for_each        = local.controllers
  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.controller[each.key].arn
}
