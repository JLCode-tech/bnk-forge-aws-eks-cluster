# -----------------------------------------------------------------------------
# TMM-external subnet outputs
# -----------------------------------------------------------------------------

output "tmm_external_subnet_ids" {
  description = "TMM-external subnet IDs (one per AZ), in availability_zones order."
  value       = aws_subnet.tmm_external[*].id
}

output "tmm_external_subnet_ids_by_az" {
  description = "AZ → TMM-external subnet ID map."
  value       = local.tmm_external_subnet_by_az
}

output "tmm_external_subnet_cidrs" {
  description = "TMM-external subnet CIDRs that were created (one per AZ)."
  value       = local.tmm_external_subnet_cidrs
}

output "tmm_external_subnets_by_az" {
  description = "AZ → TMM-external subnets, in the same shape cluster-register / cluster-create emit. cneinstall rediscovers the same set internally at apply time via the f5-bnk-role=tmm-external tag, so this output is mainly for diagnostics."
  value = [
    for i, az in var.availability_zones : {
      name = az
      subnets = [{
        cidr      = local.tmm_external_subnet_cidrs[i]
        subnet_id = aws_subnet.tmm_external[i].id
      }]
    }
  ]
}

# -----------------------------------------------------------------------------
# TMM-internal subnet outputs
# -----------------------------------------------------------------------------

output "tmm_internal_subnet_ids" {
  description = "TMM-internal subnet IDs (one per AZ), in availability_zones order."
  value       = aws_subnet.tmm_internal[*].id
}

output "tmm_internal_subnet_ids_by_az" {
  description = "AZ → TMM-internal subnet ID map."
  value       = local.tmm_internal_subnet_by_az
}

output "tmm_internal_subnet_cidrs" {
  description = "TMM-internal subnet CIDRs that were created (one per AZ)."
  value       = local.tmm_internal_subnet_cidrs
}

output "tmm_internal_subnets_by_az" {
  description = "AZ → TMM-internal subnets, structured. cneinstall rediscovers the same set internally at apply time via the f5-bnk-role=tmm-internal tag."
  value = [
    for i, az in var.availability_zones : {
      name = az
      subnets = [{
        cidr      = local.tmm_internal_subnet_cidrs[i]
        subnet_id = aws_subnet.tmm_internal[i].id
      }]
    }
  ]
}

# -----------------------------------------------------------------------------
# Node group + launch template
# -----------------------------------------------------------------------------

output "hp_node_group_arn" {
  description = "ARN of the HP managed node group. Empty when node_count_per_az = 0."
  value       = length(aws_eks_node_group.hp) > 0 ? aws_eks_node_group.hp[0].arn : ""
}

output "hp_node_group_name" {
  description = "Name of the HP managed node group. Empty when node_count_per_az = 0."
  value       = length(aws_eks_node_group.hp) > 0 ? aws_eks_node_group.hp[0].node_group_name : ""
}

output "hp_node_role_arn" {
  description = "IAM role ARN attached to HP nodes (with ENI-management inline policy)."
  value       = aws_iam_role.hp_node.arn
}

output "launch_template_id" {
  description = "Launch template ID used by the HP node group."
  value       = aws_launch_template.hp.id
}

output "hp_node_count" {
  description = "Total HP node count: node_count_per_az × availability_zone_count."
  value       = var.node_count_per_az * local.az_count
}

output "node_label_app_value" {
  description = "Value applied to the 'app' label on HP nodes. FLO uses app=f5-tmm to schedule TMM pods — keep the default unless you've changed the CNEInstance CR's match selector."
  value       = var.node_label_app
}
