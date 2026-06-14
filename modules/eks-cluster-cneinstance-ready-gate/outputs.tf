output "cneinstance_ready" {
  description = "Gate output — derived from the readiness null_resource, NOT a literal. Non-empty (the resource id) only after wait-cneinstance-ready.sh exited 0, i.e. the operator reported F5TmmAvailable && CNEControllerAvailable (or the state fallback). If the gate times out, the apply fails and this is never produced. Downstream steps (License, traffic checks) should depend on it."
  value       = null_resource.ready_gate.id
}

output "instance_namespace" {
  description = "Namespace of the CNEInstance that was gated."
  value       = var.instance_namespace
}

output "instance_name" {
  description = "Name of the CNEInstance that was gated."
  value       = var.instance_name
}
