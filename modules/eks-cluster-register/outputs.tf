output "cluster_id" {
  description = "EKS cluster ARN — used by BNK Forge for cluster registration."
  value       = data.aws_eks_cluster.existing.arn
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = data.aws_eks_cluster.existing.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint."
  value       = data.aws_eks_cluster.existing.endpoint
}

output "eks_cluster_arn" {
  description = "EKS cluster ARN (explicit name for clarity alongside cluster_id alias)."
  value       = data.aws_eks_cluster.existing.arn
}

output "eks_cluster_version" {
  description = "EKS Kubernetes minor version (e.g. \"1.30\")."
  value       = data.aws_eks_cluster.existing.version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded cluster CA certificate, for clients that build their own kubeconfig."
  value       = data.aws_eks_cluster.existing.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL — used downstream for IRSA configuration."
  value       = data.aws_eks_cluster.existing.identity[0].oidc[0].issuer
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
# Network outputs — let downstream modules auto-wire AWS subnet/AZ info that
# the EKS cluster already knows about, so users don't have to re-enter it.
# -----------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID the EKS cluster lives in."
  value       = data.aws_eks_cluster.existing.vpc_config[0].vpc_id
}

output "subnet_ids" {
  description = "All subnet IDs attached to the EKS cluster's VPC config."
  value       = data.aws_eks_cluster.existing.vpc_config[0].subnet_ids
}

output "cloud_az_subnet_mappings" {
  description = <<-EOT
    AZ → subnets list, structured for direct consumption by the
    eks-cluster-cneinstall module's cloud_az_subnet_mappings input.
    Each entry: { name = "<az>", subnets = [{ cidr, subnet_id }, ...] }.
    Discovered via data.aws_subnet against the EKS cluster's subnet IDs.
  EOT
  value       = local.az_subnet_mappings
}
