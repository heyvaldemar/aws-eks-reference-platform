# The zone the platform publishes into. ExternalDNS writes the Gateway's
# hostnames here and cert-manager answers DNS-01 challenges here; neither has
# permission anywhere else. Delegate it from the parent zone using the
# name_servers output, or certificates will not issue.
resource "aws_route53_zone" "this" {
  name          = var.domain
  comment       = "aws-eks-reference-platform: ${var.cluster_name}"
  force_destroy = true
}
