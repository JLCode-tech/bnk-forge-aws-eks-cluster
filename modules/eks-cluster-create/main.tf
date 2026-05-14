# =============================================================================
# eks-cluster-create
# =============================================================================
# Provisions a new AWS EKS cluster end-to-end for BNK using the community
# terraform-aws-modules:
#
#   - terraform-aws-modules/vpc/aws ~> 6.0
#       VPC + IGW + NAT + public/private subnets across 3 AZs (default)
#
#   - terraform-aws-modules/eks/aws ~> 21.0
#       EKS cluster + managed node group + cluster/node IAM roles + OIDC
#       provider for IRSA. IMDSv2-required, EBS-encrypted, private+public
#       endpoints — all from the module's hardened defaults.
#
# What this module adds on top:
#
#   - Tags private subnets with f5-bnk-role=tmm-external so the catalog's
#     tag-based discovery wires the BNKGateway CR automatically.
#   - Emits outputs matching eks-cluster-register's shape so the install
#     modules (bnk-prereqs, cert-manager, cert-issuer, flo, cneinstall)
#     work unchanged regardless of which provisioning path the blueprint
#     took.
#   - Synthesises a base64-encoded kubeconfig with a short-lived STS token
#     so BNK Forge can register the cluster on first scan.
#
# Inputs intentionally minimal — community modules' defaults are well-
# maintained, widely audited, and tuned for production. We expose only the
# knobs BNK actually needs.

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token != "" ? var.aws_session_token : null
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  zone_names = length(var.availability_zones) > 0 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names, 0, 3
  )

  az_count = length(local.zone_names)

  # Private subnets carved first. cidrsubnet(10.0.0.0/16, 8, i) →
  # 10.0.0.0/24, 10.0.1.0/24, 10.0.2.0/24.
  private_subnet_cidrs = [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.private_subnet_newbits, i)
  ]

  # Public subnets carved after the private ones to avoid overlap.
  public_subnet_cidrs = [
    for i in range(local.az_count) :
    cidrsubnet(var.vpc_cidr, var.public_subnet_newbits, local.az_count + i)
  ]

  common_tags = merge(var.tags, {
    "bnk-forge:module"  = "eks-cluster-create"
    "bnk-forge:cluster" = var.eks_cluster_name
  })

  # Subnet tags. The VPC module merges these with its own internal tags.
  private_subnet_tags = merge(
    {
      "kubernetes.io/role/internal-elb" = "1"
    },
    var.tag_private_subnets_for_tmm ? { "f5-bnk-role" = "tmm-external" } : {}
  )

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

# =============================================================================
# VPC — community module
# =============================================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.eks_cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.zone_names
  private_subnets = local.private_subnet_cidrs
  public_subnets  = local.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnet_tags = local.private_subnet_tags
  public_subnet_tags  = local.public_subnet_tags

  tags = local.common_tags
}

# =============================================================================
# EKS — community module
# =============================================================================
# We let the module create:
#   - The EKS control plane
#   - The managed node group with IMDSv2-required launch template
#   - The cluster + node IAM roles
#   - The IRSA OIDC provider (oidc_provider_arn output)
#
# We deliberately do NOT configure: Karpenter, Fargate profiles, multiple
# node groups, KMS secrets encryption (separate concern), or cluster access
# entries beyond the creator. Keep it minimal — BNK adds its own complexity
# on top.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.eks_cluster_name
  kubernetes_version = var.eks_cluster_version != "" ? var.eks_cluster_version : null

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.worker_instance_type]
      disk_size      = var.worker_disk_size_gb

      min_size     = var.worker_count_per_az * local.az_count
      desired_size = var.worker_count_per_az * local.az_count
      max_size     = var.worker_count_per_az * local.az_count * 2
    }
  }

  tags = local.common_tags
}

# =============================================================================
# Kubeconfig synthesis — short-lived STS token, ingested by BNK Forge on
# first scan. Matches eks-cluster-register's pattern so downstream modules
# behave identically regardless of provisioning path.
# =============================================================================

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

locals {
  kubeconfig = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = module.eks.cluster_name
    clusters = [{
      name = module.eks.cluster_name
      cluster = {
        server                     = module.eks.cluster_endpoint
        certificate-authority-data = module.eks.cluster_certificate_authority_data
      }
    }]
    contexts = [{
      name = module.eks.cluster_name
      context = {
        cluster = module.eks.cluster_name
        user    = module.eks.cluster_name
      }
    }]
    users = [{
      name = module.eks.cluster_name
      user = {
        token = data.aws_eks_cluster_auth.this.token
      }
    }]
  })

  # AZ → subnets list. Matches cluster-register's shape so cneinstall
  # consumes the same output regardless of which provisioning module ran.
  cloud_az_subnet_mappings = [
    for i in range(local.az_count) : {
      name = local.zone_names[i]
      subnets = [
        {
          cidr      = local.private_subnet_cidrs[i]
          subnet_id = module.vpc.private_subnets[i]
        }
      ]
    }
  ]

  # TMM external subnets discovered via the f5-bnk-role tag. Since this
  # module creates and tags them, we expose them directly when tagging is
  # enabled — no separate data lookup needed.
  tmm_external_subnets_by_az = var.tag_private_subnets_for_tmm ? local.cloud_az_subnet_mappings : []
}
