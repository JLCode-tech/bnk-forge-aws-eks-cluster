terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token != "" ? var.aws_session_token : null
}

data "aws_eks_cluster" "existing" {
  name = var.eks_cluster_name
}

# aws_eks_cluster_auth produces a short-lived STS token usable in the
# kubeconfig we emit. BNK Forge ingests the kubeconfig on first scan,
# well within the token validity window.
data "aws_eks_cluster_auth" "existing" {
  name = var.eks_cluster_name
}

# Look up each subnet the EKS cluster has in vpc_config.subnet_ids so we
# can expose them grouped by AZ. Downstream modules (cneinstall) consume
# this to auto-populate the cloud-network-mapping ConfigMap without
# making the user re-enter AZ/subnet IDs that EKS already knows about.
data "aws_subnet" "cluster_subnets" {
  for_each = toset(data.aws_eks_cluster.existing.vpc_config[0].subnet_ids)
  id       = each.value
}

# Expose the VPC's CIDR so downstream modules can derive sensible defaults
# for VIP ranges, app subnets, etc. without re-asking the user.
data "aws_vpc" "cluster_vpc" {
  id = data.aws_eks_cluster.existing.vpc_config[0].vpc_id
}

# List the EKS node groups so we can sum total worker capacity — used by
# cneinstall to default tmm_replicas to a sensible value bounded by the
# actual node count.
data "aws_eks_node_groups" "all" {
  cluster_name = data.aws_eks_cluster.existing.name
}

data "aws_eks_node_group" "each" {
  for_each        = toset(data.aws_eks_node_groups.all.names)
  cluster_name    = data.aws_eks_cluster.existing.name
  node_group_name = each.value
}

# Tag-based discovery of TMM data-plane subnets.
#
# Convention: customers tag the AWS subnets they want TMM data-plane VIPs
# allocated from with `f5-bnk-role=tmm-external` (one tagged subnet per AZ
# is the typical pattern). The cneinstall module consumes the output below
# to auto-build the BNKGateway CR's defaultListenerNetworks with one entry
# per AZ subnet — no manual vip_cidr required.
#
# An explicit `vip_cidr` set on cneinstall overrides discovery. If no
# subnets carry the tag AND no vip_cidr is set, cneinstall skips the
# BNKGateway CR entirely (preserves on-prem default behavior).
data "aws_subnets" "tmm_external_tagged" {
  filter {
    name   = "vpc-id"
    values = [data.aws_eks_cluster.existing.vpc_config[0].vpc_id]
  }
  tags = {
    "f5-bnk-role" = "tmm-external"
  }
}

data "aws_subnet" "tmm_external" {
  for_each = toset(data.aws_subnets.tmm_external_tagged.ids)
  id       = each.value
}

locals {
  # Group subnets by AZ. Each AZ entry holds the list of (cidr, subnet_id)
  # pairs in that AZ. Matches the shape cneinstall's
  # cloud-network-mapping ConfigMap expects.
  subnets_by_az = {
    for s in data.aws_subnet.cluster_subnets : s.availability_zone => {
      cidr      = s.cidr_block
      subnet_id = s.id
    }...
  }

  az_subnet_mappings = [
    for az, subnets in local.subnets_by_az : {
      name    = az
      subnets = subnets
    }
  ]

  # Total worker node count across all node groups in the cluster.
  # Uses scaling_config.desired_size as the canonical "what's running now"
  # number per node group. cneinstall uses this as an upper bound on
  # tmm_replicas (a TMM pod can't schedule without an available node).
  worker_node_count = sum([
    for ng in data.aws_eks_node_group.each : ng.scaling_config[0].desired_size
  ])

  # TMM external subnets discovered by tag, grouped by AZ. Same shape as
  # cloud_az_subnet_mappings so cneinstall can consume it uniformly.
  tmm_external_subnets_by_az_map = {
    for s in data.aws_subnet.tmm_external : s.availability_zone => {
      cidr      = s.cidr_block
      subnet_id = s.id
    }...
  }

  tmm_external_subnets_by_az = [
    for az, subnets in local.tmm_external_subnets_by_az_map : {
      name    = az
      subnets = subnets
    }
  ]

  kubeconfig = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = data.aws_eks_cluster.existing.name
    clusters = [{
      name = data.aws_eks_cluster.existing.name
      cluster = {
        server                     = data.aws_eks_cluster.existing.endpoint
        certificate-authority-data = data.aws_eks_cluster.existing.certificate_authority[0].data
      }
    }]
    contexts = [{
      name = data.aws_eks_cluster.existing.name
      context = {
        cluster = data.aws_eks_cluster.existing.name
        user    = data.aws_eks_cluster.existing.name
      }
    }]
    users = [{
      name = data.aws_eks_cluster.existing.name
      user = {
        token = data.aws_eks_cluster_auth.existing.token
      }
    }]
  })
}

resource "terraform_data" "registration_marker" {
  input = {
    cluster_id   = data.aws_eks_cluster.existing.arn
    cluster_name = data.aws_eks_cluster.existing.name
  }
}
