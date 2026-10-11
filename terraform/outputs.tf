# Read by the Makefile's eks-bootstrap target and passed to
# bootstrap/bootstrap.sh, which writes them into the Argo CD cluster Secret
# as the annotations platform/clusters/eks.env names. None is a credential.

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "region" {
  value = var.region
}

output "vpc_id" {
  value = aws_vpc.this.id
}

output "domain" {
  value = var.domain
}

output "cluster_issuer" {
  description = "The ClusterIssuer the Gateway certificate uses."
  value       = "letsencrypt-${var.acme_environment}"
}

output "velero_bucket" {
  value = aws_s3_bucket.velero.bucket
}

output "karpenter_node_role" {
  value = aws_iam_role.karpenter_node.name
}

output "karpenter_interruption_queue" {
  value = aws_sqs_queue.karpenter_interruption.name
}

output "name_servers" {
  description = "Delegate var.domain to these from its parent zone."
  value       = aws_route53_zone.this.name_servers
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.name}"
}
