output "license_active" {
  description = "Gate output — derived from the activation null_resource, NOT a literal. Non-empty (the resource id) only after wait-license-active.sh exited 0, i.e. the operator reported License .status.state == \"Active\". If the gate times out, the apply fails and this is never produced. Downstream steps (traffic checks) should depend on it."
  value       = null_resource.license_gate.id
}

output "license_namespace" {
  description = "Namespace where the License CR was applied and gated."
  value       = var.license_namespace
}

output "license_name" {
  description = "Name of the License CR that was applied and gated."
  value       = var.license_name
}
