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

output "effective_tmm_replicas" {
  description = "The tmm_replicas value actually applied to the CNEInstance CR. Equals var.tmm_replicas if explicitly set; otherwise min(availability_zone_count, worker_node_count)."
  value       = local.effective_tmm_replicas
}

output "cneinstance_ready" {
  description = "Gate output — true once the IRSA dance (annotate + rollout-restart) has finished. Downstream modules (License) should depend on this."
  value       = true

  depends_on = [
    null_resource.annotate_and_restart,
  ]
}
