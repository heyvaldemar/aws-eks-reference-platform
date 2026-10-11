# The system node group: a fixed, small set of Graviton nodes for the
# controllers that must run before Karpenter can provision anything (Argo CD,
# Karpenter itself, CoreDNS, the load balancer controller). Workloads get
# Karpenter capacity (manifests/aws/karpenter.yaml).

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-system-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# No CNI policy on the node: the VPC CNI gets its permissions through Pod
# Identity (addons.tf), so a pod that escapes onto the node does not inherit
# them. SSM instead of SSH for the rare time a node needs a shell.
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEC2ContainerRegistryPullOnly",
    "AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

resource "aws_launch_template" "system" {
  name_prefix = "${var.cluster_name}-system-"

  # IMDSv2 only, and one network hop: the instance can read its metadata, a
  # pod cannot reach it and borrow the node's role. Pods get AWS credentials
  # from Pod Identity instead.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.cluster_name}-system" }
  }
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  ami_type        = "AL2023_ARM_64_STANDARD"
  instance_types  = var.system_node_instance_types
  capacity_type   = "ON_DEMAND"

  scaling_config {
    min_size     = var.system_node_count
    max_size     = var.system_node_count
    desired_size = var.system_node_count
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  # Karpenter and the load balancer controller select these nodes by label.
  # No taint: Argo CD and the first add-ons have to run here before any other
  # capacity exists.
  labels = {
    "platform.heyvaldemar.com/node-group" = "system"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    # Nodes join only once the network add-ons they need are in place.
    aws_eks_addon.before_nodes,
  ]
}
