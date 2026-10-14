# Everything ADR 10 asks of the account before the first validation run.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  oidc_host = "token.actions.githubusercontent.com"
  state_key = "${local.account}-aws-eks-reference-platform-tfstate"

  # The bootstrap's own resources. No role a workflow assumes may change them:
  # a run that could detach the kill-switch or rewrite a trust policy would
  # make every guard here advisory.
  protected_roles = [
    "arn:${local.partition}:iam::${local.account}:role/platform-validation-create",
    "arn:${local.partition}:iam::${local.account}:role/platform-validation-sweep",
    "arn:${local.partition}:iam::${local.account}:role/platform-validation-budget-action",
  ]
  # Built from names, not resource references: the guardrails protect their
  # own policy, and a policy cannot refer to its own ARN.
  guardrails_arn = "arn:${local.partition}:iam::${local.account}:policy/platform-validation-guardrails"
  boundary_arn   = "arn:${local.partition}:iam::${local.account}:policy/platform-validation-boundary"
  deny_all_arn   = "arn:${local.partition}:iam::${local.account}:policy/platform-validation-deny-all"
  run_roles      = "arn:${local.partition}:iam::${local.account}:role/${var.cluster_name_prefix}*"
}

# --- GitHub OIDC ---------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# Trusted for one repository and one GitHub environment each: a workflow on
# another branch, a fork, or a job without that environment cannot assume it.
locals {
  trust = {
    for role, environment in { create = var.create_environment, sweep = var.sweeper_environment } : role => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Condition = {
          StringEquals = {
            "${local.oidc_host}:aud" = "sts.amazonaws.com"
            "${local.oidc_host}:sub" = "repo:${var.repository}:environment:${environment}"
          }
        }
      }]
    })
  }
}

# --- Guardrails every workflow role carries -------------------------------------

locals {
  # Shared by the guardrails (on the workflow roles) and the permissions
  # boundary (on every role a run creates). Without the boundary, a role with
  # AdministratorAccess escapes any deny attached to it by creating another
  # role without one and assuming it; with it, a role a run creates inherits
  # the same denies, and no role can be created without it.
  deny_statements = [
    {
      Sid      = "NoLongLivedCredentials"
      Effect   = "Deny"
      Action   = ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:UpdateLoginProfile", "iam:CreateServiceSpecificCredential"]
      Resource = "*"
    },
    {
      Sid    = "NoAccountOrBillingChanges"
      Effect = "Deny"
      Action = [
        "organizations:*", "account:*", "aws-portal:*", "billing:*", "payments:*", "tax:*",
        "budgets:*", "ce:Create*", "ce:Update*", "ce:Delete*",
      ]
      Resource = "*"
    },
    {
      Sid      = "BootstrapIsNotTheirs"
      Effect   = "Deny"
      Action   = "iam:*"
      Resource = concat(local.protected_roles, [aws_iam_openid_connect_provider.github.arn, local.deny_all_arn, local.guardrails_arn, local.boundary_arn])
    },
    {
      Sid       = "EveryRoleCarriesTheBoundary"
      Effect    = "Deny"
      Action    = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
      Resource  = "*"
      Condition = { StringNotEquals = { "iam:PermissionsBoundary" = local.boundary_arn } }
    },
    {
      Sid      = "TheBoundaryStays"
      Effect   = "Deny"
      Action   = "iam:DeleteRolePermissionsBoundary"
      Resource = "*"
    },
    {
      Sid    = "OnlyTheRunsRoles"
      Effect = "Deny"
      Action = [
        "iam:CreateRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:AttachRolePolicy", "iam:PutRolePolicy",
        "iam:DetachRolePolicy", "iam:DeleteRolePolicy", "iam:PutRolePermissionsBoundary", "iam:PassRole",
      ]
      NotResource = [local.run_roles]
    },
    {
      Sid    = "StateBucketStaysAsBuilt"
      Effect = "Deny"
      Action = [
        "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketVersioning",
        "s3:PutLifecycleConfiguration", "s3:PutBucketPublicAccessBlock", "s3:PutEncryptionConfiguration",
      ]
      Resource = aws_s3_bucket.state.arn
    },
    {
      Sid      = "ValidationZoneStays"
      Effect   = "Deny"
      Action   = "route53:DeleteHostedZone"
      Resource = aws_route53_zone.validation.arn
    },
    {
      Sid    = "OneRegion"
      Effect = "Deny"
      NotAction = [
        "iam:*", "sts:*", "route53:*", "route53domains:*", "cloudfront:*", "budgets:*", "ce:*",
        "health:*", "support:*", "organizations:*", "account:*", "tag:GetResources",
      ]
      Resource  = "*"
      Condition = { StringNotEquals = { "aws:RequestedRegion" = var.region } }
    },
  ]

  guardrails = jsonencode({ Version = "2012-10-17", Statement = local.deny_statements })
  boundary = jsonencode({
    Version   = "2012-10-17"
    Statement = concat([{ Sid = "Ceiling", Effect = "Allow", Action = "*", Resource = "*" }], local.deny_statements)
  })
}

resource "aws_iam_policy" "guardrails" {
  name   = "platform-validation-guardrails"
  policy = local.guardrails
}

resource "aws_iam_policy" "boundary" {
  name        = "platform-validation-boundary"
  description = "The permissions boundary every IAM role a validation run creates must carry."
  policy      = local.boundary
}

# --- The creation role -------------------------------------------------------------
# A validation run creates a VPC, an EKS cluster, IAM roles for its
# controllers, KMS keys, a bucket, a queue and DNS records. Writing that as an
# allow-list is an exercise in chasing AccessDenied through every provider
# release; in an account that runs nothing else, the boundary that matters is
# what the role may NOT do, which the guardrails above say, plus the
# kill-switch below.

resource "aws_iam_role" "create" {
  name                 = "platform-validation-create"
  description          = "Assumed by ${var.repository}'s validation workflow in the ${var.create_environment} environment only."
  assume_role_policy   = local.trust["create"]
  max_session_duration = 7200
}

resource "aws_iam_role_policy_attachment" "create_admin" {
  role       = aws_iam_role.create.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "create_guardrails" {
  role       = aws_iam_role.create.name
  policy_arn = aws_iam_policy.guardrails.arn
}

# --- The delete-only role -------------------------------------------------------------
# Read everything, delete what a run makes, create nothing. The kill-switch
# does not touch it, so the sweeper keeps cleaning after spending has stopped.

locals {
  sweep = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DeleteWhatARunMakes"
        Effect = "Allow"
        Action = [
          "ec2:Delete*", "ec2:TerminateInstances", "ec2:ReleaseAddress", "ec2:DisassociateAddress",
          "ec2:DetachInternetGateway", "ec2:DisassociateRouteTable", "ec2:DetachNetworkInterface",
          "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
          "elasticloadbalancing:DeleteLoadBalancer", "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:DeleteListener",
          "autoscaling:DeleteAutoScalingGroup", "autoscaling:UpdateAutoScalingGroup",
          "eks:DeleteCluster", "eks:DeleteNodegroup", "eks:DeleteAddon", "eks:DeleteAccessEntry", "eks:DeletePodIdentityAssociation",
          "kms:ScheduleKeyDeletion", "kms:DeleteAlias", "kms:DisableKey",
          "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:DeleteBucket",
          "sqs:DeleteQueue", "events:DeleteRule", "events:RemoveTargets",
          "logs:DeleteLogGroup", "secretsmanager:DeleteSecret",
        ]
        Resource = "*"
      },
      {
        Sid    = "DeleteTheRunsIamOnly"
        Effect = "Allow"
        Action = [
          "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:DetachRolePolicy", "iam:DeletePolicy", "iam:DeletePolicyVersion",
          "iam:DeleteInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
        ]
        Resource = [
          "arn:${local.partition}:iam::${local.account}:role/${var.cluster_name_prefix}*",
          "arn:${local.partition}:iam::${local.account}:policy/${var.cluster_name_prefix}*",
          "arn:${local.partition}:iam::${local.account}:instance-profile/*",
        ]
      },
      {
        Sid       = "DeleteRecordsOnly"
        Effect    = "Allow"
        Action    = "route53:ChangeResourceRecordSets"
        Resource  = "*"
        Condition = { "ForAllValues:StringEquals" = { "route53:ChangeResourceRecordSetsActions" = ["DELETE"] } }
      },
      {
        Sid      = "ReadAndRewriteTheRunState"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      },
    ]
  })
}

resource "aws_iam_role" "sweep" {
  name                 = "platform-validation-sweep"
  description          = "Assumed by ${var.repository}'s sweeper workflow in the ${var.sweeper_environment} environment only. Reads and deletes; creates nothing."
  assume_role_policy   = local.trust["sweep"]
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "sweep" {
  name   = "delete-only"
  role   = aws_iam_role.sweep.id
  policy = local.sweep
}

resource "aws_iam_role_policy_attachment" "sweep_read" {
  role       = aws_iam_role.sweep.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "sweep_guardrails" {
  role       = aws_iam_role.sweep.name
  policy_arn = aws_iam_policy.guardrails.arn
}

# --- State -----------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_key
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

locals {
  state_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TlsOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = local.state_policy
}

# --- The validation zone -------------------------------------------------------------

resource "aws_route53_zone" "validation" {
  name    = var.validation_domain
  comment = "aws-eks-reference-platform validation runs (ADR 10); delegated once, kept between runs"
}

# --- Budgets and the kill-switch --------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "platform-validation-monthly"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.kill_switch_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Credits are left out. AWS Budgets counts them by default, and an account
  # running on promotional credits pays close to nothing net, so the alerts
  # would never fire and the kill-switch would wait for the credits to run
  # out. The thresholds are on what the runs use, whoever pays for it.
  cost_types {
    include_credit = false
  }

  dynamic "notification" {
    for_each = var.alert_thresholds_usd
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "ABSOLUTE_VALUE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}

resource "aws_iam_policy" "deny_all" {
  name        = "platform-validation-deny-all"
  description = "Attached to the creation role by AWS Budgets at the kill-switch threshold."
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Sid = "KillSwitch", Effect = "Deny", Action = "*", Resource = "*" }]
  })
}

locals {
  budget_action_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "budgets.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = local.account } }
    }]
  })
}

resource "aws_iam_role" "budget_action" {
  name               = "platform-validation-budget-action"
  description        = "Lets AWS Budgets attach deny-all to the creation role, and nothing else."
  assume_role_policy = local.budget_action_trust
}

resource "aws_iam_role_policy" "budget_action" {
  name = "attach-deny-all-to-create"
  role = aws_iam_role.budget_action.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
      Resource  = aws_iam_role.create.arn
      Condition = { ArnEquals = { "iam:PolicyARN" = aws_iam_policy.deny_all.arn } }
    }]
  })
}

resource "aws_budgets_budget_action" "kill_switch" {
  budget_name        = aws_budgets_budget.monthly.name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn

  action_threshold {
    action_threshold_type  = "ABSOLUTE_VALUE"
    action_threshold_value = var.kill_switch_usd
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.deny_all.arn
      roles      = [aws_iam_role.create.name]
    }
  }

  subscriber {
    address           = var.alert_email
    subscription_type = "EMAIL"
  }
}
