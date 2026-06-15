output "cneinstance_name" {
  description = "Name of the applied CNEInstance CR."
  value       = var.instance_name
}

output "cneinstance_namespace" {
  description = "Namespace where the CNEInstance CR lives."
  value       = var.operator_namespace
}

output "cne_controller_role_arn" {
  description = "IAM role ARN assumed by the CNE controller via IRSA."
  value       = aws_iam_role.cne_controller.arn
}

output "cne_controller_role_name" {
  description = "IAM role name created for the CNE controller's IRSA binding."
  value       = aws_iam_role.cne_controller.name
}

output "cne_controller_policy_arn" {
  description = "IAM policy ARN granting EC2 VIP/ENI permissions to the CNE controller."
  value       = aws_iam_policy.cne_controller_vip.arn
}

output "cloud_network_mapping_applied" {
  description = "True if the cloud-network-mapping ConfigMap was applied (i.e. cloud_az_subnet_mappings was non-empty)."
  value       = length(var.cloud_az_subnet_mappings) > 0
}

output "bnk_gateway_applied" {
  description = "True if the BNKGateway CR (kind: F5BnkGateway) was applied (i.e. vip_cidr was non-empty)."
  value       = local.bnk_gateway_enabled
}

output "discovered_tmm_external_subnets_by_az" {
  description = "Subnets tagged f5-bnk-role=tmm-external in the cluster VPC, discovered at cneinstall apply time. Used to build the BNKGateway CR's listener networks when var.vip_cidr is unset and at least one tagged subnet exists. Empty list = nothing tagged (BNKGateway then skipped unless vip_cidr is provided)."
  value       = local.discovered_tmm_external_subnets_by_az
}

output "discovered_tmm_internal_subnets_by_az" {
  description = "Subnets tagged f5-bnk-role=tmm-internal in the cluster VPC, discovered at cneinstall apply time. Reserved for a future NAD-provisioning module that will create ens8-ipvlan-l2 referencing these. Empty list = nothing tagged (the no-HP-nodes deployment path)."
  value       = local.discovered_tmm_internal_subnets_by_az
}

output "effective_tmm_replicas" {
  description = "The tmm_replicas value actually applied to the CNEInstance CR. Equals var.tmm_replicas if explicitly set; otherwise min(availability_zone_count, worker_node_count)."
  value       = local.effective_tmm_replicas
}

# NOTE: cneinstance_ready and license_active are no longer re-exported here.
# The readiness gate and license-activation gate are now standalone chain modules
# (eks-cluster-cneinstance-ready-gate / eks-cluster-license-activation-gate) that
# export their own cneinstance_ready / license_active outputs. See #322/#323.
