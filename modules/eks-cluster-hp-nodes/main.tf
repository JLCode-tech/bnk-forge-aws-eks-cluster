# =============================================================================
# eks-cluster-hp-nodes
# =============================================================================
# Adds a dedicated high-performance EKS managed node group to an existing
# cluster for hosting TMM data-plane pods. What this module does:
#
#   1. Creates per-AZ TMM subnets in the cluster's VPC (tagged
#      f5-bnk-role=tmm-external so cneinstall auto-discovers them).
#   2. Creates a node IAM role with standard EKS worker permissions PLUS
#      ec2:CreateNetworkInterface/AttachNetworkInterface/CreateTags so the
#      bootstrap user-data can self-attach a secondary ENI.
#   3. Creates a launch template (IMDSv2-required, EBS-encrypted, custom
#      user-data) that wraps the EKS bootstrap with a pre-step that creates
#      and attaches the secondary ENI from the AZ-matching TMM subnet.
#   4. Creates an EKS managed node group using that launch template, with
#      node label app=f5-tmm so FLO schedules TMM pods here.
#
# Works for both blueprints (cluster-create greenfield and cluster-register
# brownfield) — only requires the upstream module's vpc_id, vpc_cidr,
# private_subnet_ids, availability_zones, and eks_cluster_name outputs.

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token != "" ? var.aws_session_token : null
}

data "aws_eks_cluster" "this" {
  name = var.eks_cluster_name
}

data "aws_partition" "current" {}

locals {
  az_count = length(var.availability_zones)

  # TMM subnet CIDRs — explicit override OR auto-carve from vpc_cidr.
  tmm_subnet_cidrs = length(var.tmm_subnet_cidrs) > 0 ? var.tmm_subnet_cidrs : [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.tmm_subnet_newbits, var.tmm_subnet_index_offset + i)
  ]

  common_tags = merge(var.tags, {
    "bnk-forge:module"  = "eks-cluster-hp-nodes"
    "bnk-forge:cluster" = var.eks_cluster_name
  })

  tmm_subnet_tags = merge(
    local.common_tags,
    {
      "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    },
    var.tag_subnets_for_tmm ? { "f5-bnk-role" = "tmm-external" } : {}
  )

  # Bash-case map rendered into the user-data template.
  tmm_subnet_by_az = {
    for i, az in var.availability_zones :
    az => aws_subnet.tmm[i].id
  }
}

# =============================================================================
# TMM subnets — one per AZ, used only for the secondary ENI on HP nodes.
# =============================================================================

resource "aws_subnet" "tmm" {
  count                   = local.az_count
  vpc_id                  = var.vpc_id
  cidr_block              = local.tmm_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tmm_subnet_tags, {
    Name = "${var.eks_cluster_name}-tmm-${var.availability_zones[count.index]}"
  })
}

# =============================================================================
# Node IAM role — standard EKS worker permissions + ENI-management
# =============================================================================

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hp_node" {
  name               = "${var.eks_cluster_name}-hp-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "hp_node_worker" {
  role       = aws_iam_role.hp_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "hp_node_cni" {
  role       = aws_iam_role.hp_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "hp_node_registry" {
  role       = aws_iam_role.hp_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Inline policy: bootstrap script needs to create + attach an ENI in the TMM
# subnets and tag it. Scoped narrowly to ENI-related actions.
data "aws_iam_policy_document" "hp_node_eni" {
  statement {
    sid = "ManageSecondaryENI"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:AttachNetworkInterface",
      "ec2:DetachNetworkInterface",
      "ec2:ModifyNetworkInterfaceAttribute",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeInstances",
      "ec2:DescribeSubnets",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
      "ec2:CreateTags"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "hp_node_eni" {
  name   = "${var.eks_cluster_name}-hp-node-eni"
  role   = aws_iam_role.hp_node.id
  policy = data.aws_iam_policy_document.hp_node_eni.json
}

# =============================================================================
# Launch template — bakes IMDSv2, EBS encryption, and the secondary-ENI
# bootstrap user-data into the HP node image.
# =============================================================================

locals {
  userdata_script = templatefile(
    "${path.module}/manifests/launch-template-userdata.sh.tftpl",
    {
      eks_cluster_name           = var.eks_cluster_name
      tmm_subnet_by_az           = local.tmm_subnet_by_az
      secondary_eni_device_index = var.secondary_eni_device_index
      additional_ips_per_eni     = var.additional_ips_per_eni
    }
  )

  # MIME multipart so EKS's own bootstrap runs after our pre-step.
  # AL2023 images expect this format; EKS managed node groups inject their
  # own boot.sh as a separate MIME part automatically.
  userdata_mime = <<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="==BOUNDARY=="

    --==BOUNDARY==
    Content-Type: text/x-shellscript; charset="us-ascii"

    ${replace(local.userdata_script, "\n", "\n    ")}
    --==BOUNDARY==--
  EOT
}

resource "aws_launch_template" "hp" {
  name_prefix = "${var.eks_cluster_name}-hp-"
  description = "BNK HP TMM nodes — IMDSv2, EBS-encrypted, secondary ENI bootstrap."

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_disk_size_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(local.userdata_mime)

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.eks_cluster_name}-hp-node"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.common_tags
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# EKS managed node group — uses the launch template above.
# =============================================================================

resource "aws_eks_node_group" "hp" {
  count = var.node_count_per_az > 0 ? 1 : 0

  cluster_name    = data.aws_eks_cluster.this.name
  node_group_name = "${var.eks_cluster_name}-hp"
  node_role_arn   = aws_iam_role.hp_node.arn
  subnet_ids      = var.node_subnet_ids

  instance_types = [var.instance_type]
  ami_type       = "AL2023_x86_64_STANDARD"

  release_version = var.eks_ami_release_version != "" ? var.eks_ami_release_version : null

  launch_template {
    id      = aws_launch_template.hp.id
    version = aws_launch_template.hp.latest_version
  }

  scaling_config {
    desired_size = var.node_count_per_az * local.az_count
    min_size     = var.node_count_per_az * local.az_count
    max_size     = var.node_count_per_az * local.az_count * 2
  }

  labels = {
    app                = var.node_label_app
    "bnk-forge/role"   = "hp-tmm"
    "bnk-forge/module" = "eks-cluster-hp-nodes"
  }

  dynamic "taint" {
    for_each = var.node_taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.hp_node_worker,
    aws_iam_role_policy_attachment.hp_node_cni,
    aws_iam_role_policy_attachment.hp_node_registry,
    aws_iam_role_policy.hp_node_eni,
    aws_subnet.tmm,
  ]
}
