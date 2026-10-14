# The zone the platform publishes into. ExternalDNS writes the Gateway's
# hostnames here and cert-manager answers DNS-01 challenges here; neither has
# permission anywhere else. Delegate it from the parent zone using the
# name_servers output, or certificates will not issue.
#
# With var.zone_id set, an existing zone is used instead and nothing is
# created: the validation runs of ADR 10 pass the persistent, already
# delegated zone from terraform/bootstrap-aws, so a run never waits on
# delegation and never deletes the zone it did not make.
resource "aws_route53_zone" "this" {
  count         = var.zone_id == "" ? 1 : 0
  name          = var.domain
  comment       = "aws-eks-reference-platform: ${var.cluster_name}"
  force_destroy = true
}

data "aws_route53_zone" "existing" {
  count   = var.zone_id == "" ? 0 : 1
  zone_id = var.zone_id

  lifecycle {
    postcondition {
      condition     = trimsuffix(self.name, ".") == var.domain
      error_message = "zone_id names a zone for ${self.name}, not for var.domain (${var.domain})."
    }
  }
}

locals {
  zone_arn          = var.zone_id == "" ? aws_route53_zone.this[0].arn : data.aws_route53_zone.existing[0].arn
  zone_name_servers = var.zone_id == "" ? aws_route53_zone.this[0].name_servers : data.aws_route53_zone.existing[0].name_servers
}
