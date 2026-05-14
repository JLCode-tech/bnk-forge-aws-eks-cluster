output "tmm_subnet_ids" {
  description = "TMM subnet IDs (one per AZ), in availability_zones order."
  value       = aws_subnet.tmm[*].id
}

output "tmm_subnet_ids_by_az" {
  description = "AZ → TMM subnet ID map. Useful for cross-referencing with cluster-register / cluster-create outputs."
  value       = local.tmm_subnet_by_az
}

output "tmm_subnet_cidrs" {
  description = "TMM subnet CIDRs that were created (one per AZ)."
  value       = local.tmm_subnet_cidrs
}

output "tmm_external_subnets_by_az" {
  description = "AZ → TMM external subnets, in the same shape cluster-register / cluster-create emit. Override the cneinstall input of the same name when explicitly chaining HP-nodes ahead of cneinstall to use these subnets instead of the upstream provisioner's tagged subnets."
  value = [
    for i, az in var.availability_zones : {
      name = az
      subnets = [{
        cidr      = local.tmm_subnet_cidrs[i]
        subnet_id = aws_subnet.tmm[i].id
      }]
    }
  ]
}

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
  description = "Value applied to the 'app' label on HP nodes. cneinstall uses 'app=f5-tmm' to schedule TMM pods — keep this value unless you've overridden the corresponding match in your CNEInstance CR."
  value       = var.node_label_app
}
