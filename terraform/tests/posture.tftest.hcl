# What the EKS configuration promises, checked on a plan against a mocked AWS
# provider: no account, no credentials, no cost. tests/plant_violations.py
# breaks each promise on a copy of the configuration and fails if this test
# stays green.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c"]
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:sts::123456789012:assumed-role/platform-admin/session"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:role/platform-admin"
    }
  }
}

# Policies embed ARNs AWS only assigns at apply time; fixed values, used
# during plan, make the policy text known so the runs below can read it.
override_resource {
  target          = aws_kms_key.data
  override_during = plan
  values          = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
}
override_resource {
  target          = aws_route53_zone.this
  override_during = plan
  values          = { arn = "arn:aws:route53:::hostedzone/Z0000000000000000000" }
}
override_resource {
  target          = aws_s3_bucket.velero
  override_during = plan
  values          = { arn = "arn:aws:s3:::reference-platform-velero-123456789012" }
}
override_resource {
  target          = aws_iam_role.karpenter_node
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:role/reference-platform-karpenter-node" }
}
override_resource {
  target          = aws_sqs_queue.karpenter_interruption
  override_during = plan
  values          = { arn = "arn:aws:sqs:us-east-1:123456789012:reference-platform-karpenter" }
}

variables {
  domain                               = "platform.example.com"
  cluster_endpoint_public_access_cidrs = ["203.0.113.10/32"]
}

run "control_plane" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.version == "1.37"
    error_message = "the cluster runs Kubernetes 1.37"
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API"
    error_message = "access is managed with access entries only (authentication_mode API)"
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "the creator gets no implicit admin; admins are listed access entries"
  }
  assert {
    condition     = contains(aws_eks_cluster.this.encryption_config[0].resources, "secrets")
    error_message = "Kubernetes Secrets are envelope-encrypted with KMS"
  }
  assert {
    condition     = contains(aws_eks_cluster.this.enabled_cluster_log_types, "audit")
    error_message = "the audit log is on"
  }
  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD"
    error_message = "standard support only: no silent move to extended support pricing"
  }
  assert {
    condition     = !contains(aws_eks_cluster.this.vpc_config[0].public_access_cidrs, "0.0.0.0/0")
    error_message = "the public API endpoint is not open to the whole internet"
  }
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access
    error_message = "nodes reach the API privately"
  }
  assert {
    condition = (
      aws_eks_access_entry.admin["arn:aws:iam::123456789012:role/platform-admin"].principal_arn == "arn:aws:iam::123456789012:role/platform-admin" &&
      aws_eks_access_policy_association.admin["arn:aws:iam::123456789012:role/platform-admin"].principal_arn == "arn:aws:iam::123456789012:role/platform-admin"
    )
    error_message = "the role running Terraform (not its STS session) gets an access entry and the admin policy"
  }
}

run "keys_and_logs" {
  command = plan

  assert {
    condition     = aws_kms_key.eks.enable_key_rotation && aws_kms_key.logs.enable_key_rotation && aws_kms_key.data.enable_key_rotation
    error_message = "every KMS key rotates"
  }
  assert {
    condition     = aws_flow_log.this.traffic_type == "ALL"
    error_message = "flow logs record accepted and rejected traffic"
  }
  assert {
    condition     = aws_cloudwatch_log_group.cluster.retention_in_days > 0 && aws_cloudwatch_log_group.flow_logs.retention_in_days > 0
    error_message = "log groups have a retention, not forever"
  }
}

run "nodes" {
  command = plan

  assert {
    condition     = aws_launch_template.system.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 only on system nodes"
  }
  assert {
    condition     = aws_launch_template.system.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "pods cannot reach the instance metadata service (hop limit 1)"
  }
  assert {
    condition     = aws_launch_template.system.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "node root volumes are encrypted"
  }
  assert {
    condition     = length(aws_eks_node_group.system.remote_access) == 0
    error_message = "no SSH access to nodes; SSM instead"
  }
  assert {
    condition     = aws_eks_node_group.system.ami_type == "AL2023_ARM_64_STANDARD"
    error_message = "system nodes run Amazon Linux 2023 on Graviton"
  }
  assert {
    condition     = alltrue([for s in aws_subnet.public : !s.map_public_ip_on_launch]) && alltrue([for s in aws_subnet.private : !s.map_public_ip_on_launch])
    error_message = "no subnet hands out public IPs"
  }
  assert {
    condition     = jsondecode(aws_eks_addon.before_nodes["vpc-cni"].configuration_values).enableNetworkPolicy == "true"
    error_message = "the VPC CNI enforces NetworkPolicies"
  }
}

run "controller_identities" {
  command = plan

  assert {
    condition = {
      for k, v in aws_eks_pod_identity_association.controller : k => "${v.namespace}/${v.service_account}"
      } == {
      "aws-load-balancer-controller" = "kube-system/aws-load-balancer-controller"
      "cert-manager"                 = "cert-manager/cert-manager"
      "external-dns"                 = "external-dns/external-dns"
      "external-secrets"             = "external-secrets/external-secrets"
      "karpenter"                    = "karpenter/karpenter"
      "velero"                       = "velero/velero"
    }
    error_message = "each controller's Pod Identity matches the namespace and service account its values file sets"
  }
  assert {
    condition     = strcontains(local.controllers["external-secrets"].policy, ":secret:demo/*")
    error_message = "External Secrets reads only under demo/"
  }
  assert {
    condition     = strcontains(local.controllers["cert-manager"].policy, "_acme-challenge.*")
    error_message = "cert-manager may only write ACME challenge records"
  }
}

run "backups" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_public_access_block.velero.block_public_acls &&
      aws_s3_bucket_public_access_block.velero.block_public_policy &&
      aws_s3_bucket_public_access_block.velero.ignore_public_acls &&
      aws_s3_bucket_public_access_block.velero.restrict_public_buckets
    )
    error_message = "the backup bucket can never be public"
  }
  assert {
    condition     = aws_s3_bucket_versioning.velero.versioning_configuration[0].status == "Enabled"
    error_message = "backup objects are versioned"
  }
  assert {
    condition     = one([for r in aws_s3_bucket_server_side_encryption_configuration.velero.rule : one(r.apply_server_side_encryption_by_default).sse_algorithm]) == "aws:kms"
    error_message = "backups are encrypted with the platform's KMS key"
  }
  assert {
    condition     = strcontains(aws_s3_bucket_policy.velero.policy, "aws:SecureTransport")
    error_message = "the backup bucket refuses plain HTTP"
  }
  assert {
    condition     = aws_sqs_queue.karpenter_interruption.sqs_managed_sse_enabled
    error_message = "the interruption queue is encrypted"
  }
}

run "refuses_an_api_open_to_the_internet" {
  command = plan

  variables {
    cluster_endpoint_public_access_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.cluster_endpoint_public_access_cidrs]
}

# A validation run (ADR 10) passes the persistent zone from
# terraform/bootstrap-aws: nothing is created, the controllers are confined
# to that zone, and a zone for another domain is refused.
run "existing_zone" {
  command = plan

  variables {
    zone_id = "Z0EXISTING00000000000"
  }

  override_data {
    target = data.aws_route53_zone.existing
    values = {
      name         = "platform.example.com."
      arn          = "arn:aws:route53:::hostedzone/Z0EXISTING00000000000"
      name_servers = ["ns-1.example.net"]
    }
  }

  assert {
    condition     = length(aws_route53_zone.this) == 0
    error_message = "with zone_id set, no zone is created"
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.controller["external-dns"].policy, "Z0EXISTING00000000000")
    error_message = "ExternalDNS may write only to the existing zone"
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.controller["cert-manager"].policy, "Z0EXISTING00000000000")
    error_message = "cert-manager may answer challenges only in the existing zone"
  }
}

run "existing_zone_for_another_domain" {
  command = plan

  variables {
    zone_id = "Z0OTHER0000000000000"
  }

  override_data {
    target = data.aws_route53_zone.existing
    values = {
      name = "other.example.org."
      arn  = "arn:aws:route53:::hostedzone/Z0OTHER0000000000000"
    }
  }

  expect_failures = [data.aws_route53_zone.existing]
}
