output "nad_external_name" {
  description = "Name of the external NetworkAttachmentDefinition. Use this as the network_attachments[0] value in cneinstall."
  value       = var.nad_external_name
}

output "nad_internal_name" {
  description = "Name of the internal NetworkAttachmentDefinition. Use this as the network_attachments[1] value in cneinstall."
  value       = var.nad_internal_name
}

output "nad_namespace" {
  description = "Namespace where the NADs were created."
  value       = var.nad_namespace
}

output "nad_external_static_address" {
  description = "Resolved static-address placeholder used in the external NAD's ipam stanza. Either the explicit override, the cidrhost+1 of the first discovered tmm-external subnet, or the fallback."
  value       = local.nad_external_static_address
}

output "nad_internal_static_address" {
  description = "Resolved static-address placeholder used in the internal NAD's ipam stanza. Same resolution order as external."
  value       = local.nad_internal_static_address
}

output "discovered_tmm_external_cidrs" {
  description = "TMM-external subnet CIDRs the module discovered via the f5-bnk-role=tmm-external tag. Sorted. Empty list = no subnets tagged in this VPC."
  value       = local.tmm_external_cidrs
}

output "discovered_tmm_internal_cidrs" {
  description = "TMM-internal subnet CIDRs the module discovered via the f5-bnk-role=tmm-internal tag. Sorted."
  value       = local.tmm_internal_cidrs
}

output "nads_applied" {
  description = "Gate output — true once both NADs have been applied. Downstream modules (cneinstall) should depend on this so they only render the CNEInstance CR after the NADs exist."
  value       = true

  depends_on = [
    null_resource.nad_external,
    null_resource.nad_internal,
  ]
}
