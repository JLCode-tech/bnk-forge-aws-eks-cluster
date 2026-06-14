# Example usage for the cneinstance-ready-gate module.
#
# Call it as a sub-module immediately after the step that applies the
# CNEInstance CR, gating downstream work on the operator's real .status.

module "ready_gate" {
  source = "../cneinstance-ready-gate"

  # Share the wrapper's already-materialised kubeconfig.
  kubeconfig_file = local_sensitive_file.kubeconfig.filename

  instance_namespace = var.operator_namespace # forge default: f5-operator
  instance_name      = var.instance_name

  # Optional tuning (defaults shown):
  # cne_crd_name              = "cneinstances.k8s.f5.com"
  # condition_timeout_seconds = 570
  # crd_timeout_seconds       = 300
  # poll_interval_seconds     = 30

  depends_on = [null_resource.cneinstance]
}

output "cneinstance_ready" {
  value = module.ready_gate.cneinstance_ready
}
