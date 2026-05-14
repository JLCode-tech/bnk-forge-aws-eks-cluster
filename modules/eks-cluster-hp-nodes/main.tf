# =============================================================================
# eks-cluster-hp-nodes
# =============================================================================
# Adds a dedicated high-performance EKS managed node group to an existing
# cluster for hosting TMM data-plane pods. Implements the generic 3-interface
# TMM model: CNI (ens5) + external (ens7) + internal (ens8).
#
# What this module does:
#
#   1. Creates per-AZ TMM-external subnets (tagged f5-bnk-role=tmm-external)
#      and per-AZ TMM-internal subnets (tagged f5-bnk-role=tmm-internal). The
#      cneinstall module rediscovers these at apply time to wire the
#      BNKGateway CR's listener networks.
#   2. Creates a node IAM role with standard EKS worker permissions plus
#      scoped ec2:CreateNetworkInterface / AttachNetworkInterface / CreateTags
#      so the bootstrap user-data can self-attach the two secondary ENIs.
#   3. Creates a launch template (IMDSv2-required, EBS-encrypted) with custom
#      user-data that wraps EKS's own bootstrap: at first boot the script
#      creates + attaches two secondary ENIs, one in the AZ-matching TMM-
#      external subnet (device_index 2 → ens7) and one in the AZ-matching
#      TMM-internal subnet (device_index 3 → ens8), each tagged
#      node.k8s.amazonaws.com/no_manage=true so VPC CNI ignores them.
#   4. Creates an EKS managed node group using that launch template, with
#      node label app=f5-tmm so FLO schedules TMM pods here, and optional
#      taints for full pool dedication.
#
# Works for both blueprints (cluster-create greenfield and cluster-register
# brownfield) — only requires the upstream module's vpc_id, vpc_cidr,
# private_subnet_ids, availability_zones, and eks_cluster_name outputs.
#
# NetworkAttachmentDefinitions for ens7 and ens8 are a manual prerequisite
# until a dedicated NAD-provisioning module exists. The variant blueprints
# reference these by name (ens7-ipvlan-l2 + ens8-ipvlan-l2) in the
# CNEInstance CR's networkAttachments field.

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

  # TMM-external subnet CIDRs (explicit override OR auto-carve).
  tmm_external_subnet_cidrs = length(var.tmm_external_subnet_cidrs) > 0 ? var.tmm_external_subnet_cidrs : [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.tmm_external_subnet_newbits, var.tmm_external_subnet_index_offset + i)
  ]

  # TMM-internal subnet CIDRs (explicit override OR auto-carve).
  tmm_internal_subnet_cidrs = length(var.tmm_internal_subnet_cidrs) > 0 ? var.tmm_internal_subnet_cidrs : [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.tmm_internal_subnet_newbits, var.tmm_internal_subnet_index_offset + i)
  ]

  common_tags = merge(var.tags, {
    "bnk-forge:module"  = "eks-cluster-hp-nodes"
    "bnk-forge:cluster" = var.eks_cluster_name
  })

  tmm_external_subnet_tags = merge(
    local.common_tags,
    {
      "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    },
    var.tag_subnets_for_tmm ? { "f5-bnk-role" = "tmm-external" } : {}
  )

  tmm_internal_subnet_tags = merge(
    local.common_tags,
    {
      "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    },
    var.tag_subnets_for_tmm ? { "f5-bnk-role" = "tmm-internal" } : {}
  )

  # AZ → subnet ID maps rendered into the user-data template.
  tmm_external_subnet_by_az = {
    for i, az in var.availability_zones :
    az => aws_subnet.tmm_external[i].id
  }

  tmm_internal_subnet_by_az = {
    for i, az in var.availability_zones :
    az => aws_subnet.tmm_internal[i].id
  }
}

# =============================================================================
# TMM-external subnets — one per AZ (client-facing data plane)
# =============================================================================

resource "aws_subnet" "tmm_external" {
  count                   = local.az_count
  vpc_id                  = var.vpc_id
  cidr_block              = local.tmm_external_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tmm_external_subnet_tags, {
    Name = "${var.eks_cluster_name}-tmm-ext-${var.availability_zones[count.index]}"
  })
}

# =============================================================================
# TMM-internal subnets — one per AZ (backend/origin data plane)
# =============================================================================

resource "aws_subnet" "tmm_internal" {
  count                   = local.az_count
  vpc_id                  = var.vpc_id
  cidr_block              = local.tmm_internal_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.tmm_internal_subnet_tags, {
    Name = "${var.eks_cluster_name}-tmm-int-${var.availability_zones[count.index]}"
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

# Inline policy: bootstrap script needs to create + attach two ENIs and tag
# them. Scoped to ENI actions only.
data "aws_iam_policy_document" "hp_node_eni" {
  statement {
    sid = "ManageSecondaryENIs"
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
# Launch template — IMDSv2, EBS encryption, dual-ENI bootstrap user-data
# =============================================================================

locals {
  userdata_script = templatefile(
    "${path.module}/manifests/launch-template-userdata.sh.tftpl",
    {
      eks_cluster_name          = var.eks_cluster_name
      tmm_external_subnet_by_az = local.tmm_external_subnet_by_az
      tmm_internal_subnet_by_az = local.tmm_internal_subnet_by_az
      external_eni_device_index = var.external_eni_device_index
      internal_eni_device_index = var.internal_eni_device_index
      additional_ips_per_eni    = var.additional_ips_per_eni
    }
  )

  # MIME multipart so EKS's own bootstrap runs after our pre-step.
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
  description = "BNK HP TMM nodes — IMDSv2, EBS-encrypted, dual secondary ENI bootstrap (external + internal)."

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
# EKS managed node group
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
    aws_subnet.tmm_external,
    aws_subnet.tmm_internal,
  ]
}
