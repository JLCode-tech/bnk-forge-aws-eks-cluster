output "heal_applied" {
  description = "Gate output — true once the best-effort heal step has run. The readiness gate should depend on this so the heals run before the gate evaluates."
  value       = true

  depends_on = [null_resource.tmm_heal]
}
