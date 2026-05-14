output "multus_installed" {
  description = "True if this module applied the Multus daemonset (install_multus = true)."
  value       = var.install_multus
}

output "multus_manifest_url" {
  description = "Resolved Multus daemonset URL applied to the cluster."
  value       = local.multus_url
}

output "multus_ready" {
  description = "Gate output — true once the daemonset has rolled out and the NetworkAttachmentDefinition CRD is Established. Downstream NAD-creating modules should depend on this so they only apply NAD CRs after Multus is fully up."
  value       = true

  depends_on = [
    null_resource.multus_install,
  ]
}
