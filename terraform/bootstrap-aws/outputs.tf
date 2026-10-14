# These become the GitHub environments' variables (none is a secret):
#   aws-validation: AWS_REGION, AWS_CREATE_ROLE_ARN, TF_STATE_BUCKET, VALIDATION_DOMAIN, VALIDATION_ZONE_ID,
#                   IAM_PERMISSIONS_BOUNDARY
#   aws-sweeper:    AWS_REGION, AWS_SWEEP_ROLE_ARN, TF_STATE_BUCKET

output "region" {
  value = var.region
}

output "create_role_arn" {
  value = aws_iam_role.create.arn
}

output "iam_permissions_boundary" {
  description = "Passed to every validation run as var.iam_permissions_boundary."
  value       = aws_iam_policy.boundary.arn
}

output "sweep_role_arn" {
  value = aws_iam_role.sweep.arn
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "validation_domain" {
  value = var.validation_domain
}

output "validation_zone_id" {
  value = aws_route53_zone.validation.zone_id
}

output "name_servers" {
  description = "Delegate validation_domain to these from its parent zone, once."
  value       = aws_route53_zone.validation.name_servers
}
