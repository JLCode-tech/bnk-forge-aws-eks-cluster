# =============================================================================
# Outputs matching eks-cluster-register's shape so downstream install modules
# (bnk-prereqs, cert-manager, cert-issuer, flo, cneinstall) work unchanged
# regardless of which provisioning path the blueprint took.
# =============================================================================

output "cluster_id" {
  description = "EKS cluster ARN — used by BNK Forge for cluster registration."
  value       = module.eks.cluster_arn
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint."
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_arn" {
  description = "EKS cluster ARN."
  value       = module.eks.cluster_arn
}

output "eks_cluster_version" {
  description = "EKS Kubernetes minor version."
  value       = module.eks.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL — used downstream for IRSA configuration."
  value       = module.eks.cluster_oidc_issuer_url
}

output "region" {
  description = "AWS region for the cluster."
  value       = var.aws_region
}

output "kubeconfig" {
  description = "Base64-encoded kubeconfig with a short-lived STS token. BNK Forge ingests this on first scan."
  value       = base64encode(local.kubeconfig)
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Network outputs (matching cluster-register's auto-discovery shape)
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC this module created."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "Primary CIDR block of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "subnet_ids" {
  description = "All subnet IDs (private + public) attached to the EKS cluster."
  value       = concat(module.vpc.private_subnets, module.vpc.public_subnets)
}

output "private_subnet_ids" {
  description = "Private subnet IDs only — where EKS worker nodes run."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs (have IGW route)."
  value       = module.vpc.public_subnets
}

output "cloud_az_subnet_mappings" {
  description = "AZ → subnets list (private subnets), matching cluster-register's output shape. Consumed by cneinstall for the cloud-network-mapping ConfigMap."
  value       = local.cloud_az_subnet_mappings
}

output "tmm_external_subnets_by_az" {
  description = "AZ → TMM external subnets list (private subnets tagged f5-bnk-role=tmm-external). Empty when tag_private_subnets_for_tmm = false. cneinstall consumes this to auto-build the BNKGateway CR's defaultListenerNetworks."
  value       = local.tmm_external_subnets_by_az
}

output "availability_zone_count" {
  description = "Number of distinct AZs the cluster spans."
  value       = local.az_count
}

output "worker_node_count" {
  description = "Total worker node count: worker_count_per_az × az_count."
  value       = var.worker_count_per_az * local.az_count
}

# -----------------------------------------------------------------------------
# Module-specific outputs (not in cluster-register; useful for follow-on work)
# -----------------------------------------------------------------------------

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider created for IRSA. cneinstall derives this independently from cluster_oidc_issuer_url; this output is for any downstream module that wants the ARN directly."
  value       = module.eks.oidc_provider_arn
}

output "node_group_iam_role_arns" {
  description = "Map of EKS managed node group name → IAM role ARN. Useful when downstream modules need to grant node-side permissions."
  value       = { for k, v in module.eks.eks_managed_node_groups : k => v.iam_role_arn }
}
