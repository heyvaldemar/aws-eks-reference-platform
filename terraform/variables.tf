variable "region" {
  description = "AWS region for every resource."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster; also the prefix of every named resource."
  type        = string
  default     = "reference-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.cluster_name))
    error_message = "Use 3 to 32 lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, in EKS standard support. See https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html"
  type        = string
  default     = "1.37"
}

variable "domain" {
  description = <<-EOT
    The DNS name the platform serves under, such as platform.example.com.
    Terraform creates a Route 53 hosted zone for it; delegate the zone from
    your registrar or parent zone (the name servers are an output) before
    expecting certificates. Applications are published as <name>.<domain>.
  EOT
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a DNS name such as platform.example.com."
  }
}

variable "zone_id" {
  description = <<-EOT
    An existing Route 53 hosted zone for var.domain, already delegated. Empty
    (the default): Terraform creates the zone. Validation runs (ADR 10) pass
    the persistent zone from terraform/bootstrap-aws.
  EOT
  type        = string
  default     = ""
}

variable "acme_environment" {
  description = "Which Let's Encrypt the Gateway certificate comes from: staging (untrusted, generous limits) or production."
  type        = string
  default     = "staging"

  validation {
    condition     = contains(["staging", "production"], var.acme_environment)
    error_message = "acme_environment is staging or production."
  }
}

variable "cluster_endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the Kubernetes API over the internet. There is no
    default: the Makefile passes the caller's own address as a /32. Nodes and
    pods reach the API privately whatever this says.
  EOT
  type        = list(string)

  validation {
    condition = length(var.cluster_endpoint_public_access_cidrs) > 0 && alltrue([
      for c in var.cluster_endpoint_public_access_cidrs : can(cidrhost(c, 0)) && !endswith(c, "/0")
    ])
    error_message = "List at least one CIDR, and no /0: an API server open to the whole internet is not a default this configuration offers."
  }
}

variable "admin_principal_arns" {
  description = "IAM role or user ARNs given cluster-admin through EKS access entries, in addition to the principal running Terraform."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC. Each availability zone gets a /19 private and a /22 public subnet."
  type        = string
  default     = "10.42.0.0/16"
}

variable "availability_zone_count" {
  description = "How many availability zones the subnets span."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 3
    error_message = "Use 2 or 3 zones: EKS needs at least two, and the subnet plan holds three."
  }
}

variable "nat_gateway_count" {
  description = <<-EOT
    NAT gateways for private-subnet egress. One costs about a third of three
    and is a single-zone dependency for outbound traffic; set it to
    availability_zone_count for zone-independent egress.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.nat_gateway_count >= 1 && var.nat_gateway_count <= 3
    error_message = "Use between 1 and 3 NAT gateways."
  }
}

variable "system_node_instance_types" {
  description = "Instance types of the managed node group that runs the platform's controllers before Karpenter exists. Graviton (arm64)."
  type        = list(string)
  default     = ["t4g.large"]
}

variable "system_node_count" {
  description = "Size of the system node group."
  type        = number
  default     = 2

  validation {
    condition     = var.system_node_count >= 2
    error_message = "Two or more: one system node is an outage at the first node replacement."
  }
}

variable "velero_bucket_force_destroy" {
  description = "Whether `terraform destroy` may delete the Velero bucket with backups still in it. true keeps `make eks-down` to one command; set false for anything whose backups matter."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention of the control-plane and VPC flow logs in CloudWatch."
  type        = number
  default     = 30
}

variable "run_id" {
  description = "Tag on every resource identifying the run that created it; CI sets one per run so a residue search and a cost report can find exactly that run's resources."
  type        = string
  default     = "manual"
}

variable "tags" {
  description = "Extra tags on every resource."
  type        = map(string)
  default     = {}
}
