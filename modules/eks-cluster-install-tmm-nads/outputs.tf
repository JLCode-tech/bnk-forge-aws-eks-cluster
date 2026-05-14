output "multus_installed" {
  description = "True if this module applied the Multus daemonset (install_multus = true)."
  value       = var.install_multus
}

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

output "nads_applied" {
  description = "Gate output — true once both NADs have been applied. Downstream modules (cneinstall) should depend on this so they only render the CNEInstance CR after the NADs exist."
  value       = true

  depends_on = [
    null_resource.nad_external,
    null_resource.nad_internal,
  ]
}
