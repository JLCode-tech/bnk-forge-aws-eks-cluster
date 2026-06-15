output "hugepages_installed" {
  description = "True if this module applied the hugepages-setup DaemonSet (install_hugepages = true)."
  value       = var.install_hugepages
}

output "hugepages_ready" {
  description = "Gate output — true once the DaemonSet has rolled out on all role=bnk nodes. Downstream modules that require hugepages-2Mi capacity (cneinstall, cneinstance) should depend on this output."
  value       = true

  depends_on = [
    null_resource.hugepages_install,
  ]
}
