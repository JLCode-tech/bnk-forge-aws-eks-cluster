# Example usage for the license-activation-gate module.
#
# Call it as a sub-module immediately after the cneinstance-ready-gate (P1),
# so the license is applied + activated only once the CNEInstance is
# functionally ready.

module "license_activation_gate" {
  source = "../license-activation-gate"

  # Share the wrapper's already-materialised kubeconfig.
  kubeconfig_file = local_sensitive_file.kubeconfig.filename

  license_namespace = var.operator_namespace # forge default: f5-operator
  jwt_token         = var.jwt_token          # same secret FLO takes

  # Optional tuning (defaults shown):
  # license_name               = "bnk-license"
  # operation_mode             = "connected"
  # license_crd_name           = "licenses.k8s.f5net.com"
  # teem_cert_url              = "https://product.apis.f5.com/ee/v1"
  # teem_entitlement_url       = "https://product-s.apis.f5.com/ee/v1"
  # teem_initial_config_url    = "https://product-s.apis.f5.com/ee/v1"
  # activation_timeout_seconds = 570
  # crd_timeout_seconds        = 300
  # poll_interval_seconds      = 30

  depends_on = [module.ready_gate]
}

output "license_active" {
  value = module.license_activation_gate.license_active
}
