# =============================================================================
# cneinstance-ready-gate
# =============================================================================
# Cloud-agnostic primitive: an honest readiness gate for a BNK CNEInstance.
#
# After a CNEInstance CR is applied, the operator (FLO + CNE controller) rolls
# out the BNK runtime asynchronously. A deploy must not declare success until
# the operator's own .status says the instance is functional — otherwise it
# reports "ready" against a cluster that is not licensed and cannot pass
# traffic (the D-017 "HTTP 200 ≠ operation success" class of bug, baked into
# the blueprint).
#
# This module runs scripts/wait-cneinstance-ready.sh, which:
#   1. waits for the CNEInstance CRD to be registered (pre-gate), then
#   2. polls the named CNEInstance until BOTH F5TmmAvailable and
#      CNEControllerAvailable conditions are True (OR the back-compat
#      status.state ∈ {Ready,Running} fallback), and
#   3. on timeout dumps pod diagnostics and exits 1 so Terraform fails closed.
#
# It deliberately does NOT gate on the rollup `Available` condition — see the
# H1 note in the script. Logic ported from awsbnkctl phase25_activation_poll.go.
#
# Cloud-agnostic by design: a CNEInstance CR + operator conditions are
# identical on every cloud. Per-cloud catalogs vendor this and call it as a
# sub-module after their cneinstall step, passing their own namespace/name vars.

resource "local_sensitive_file" "kubeconfig" {
  count = var.kubeconfig_file == "" ? 1 : 0

  filename        = "${path.module}/work/kubeconfig"
  file_permission = "0600"
  content         = try(local.forge_kubeconfig, var.forge_kubeconfig_content)
}

locals {
  # Prefer an explicit kubeconfig path passed by the wrapper (the EKS module
  # already materialises one via local_sensitive_file.kubeconfig); otherwise
  # materialise our own from Forge-injected content.
  kubeconfig_path = var.kubeconfig_file != "" ? var.kubeconfig_file : one(local_sensitive_file.kubeconfig[*].filename)
}

resource "null_resource" "ready_gate" {
  triggers = {
    namespace         = var.instance_namespace
    name              = var.instance_name
    crd               = var.cne_crd_name
    condition_timeout = tostring(var.condition_timeout_seconds)
    crd_timeout       = tostring(var.crd_timeout_seconds)
    crd_poll_interval = tostring(var.crd_poll_interval_seconds)
    poll_interval     = tostring(var.poll_interval_seconds)
    kubeconfig_file   = local.kubeconfig_path
    script_hash       = filesha256("${path.module}/scripts/wait-cneinstance-ready.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KUBECTL            = "kubectl --kubeconfig ${local.kubeconfig_path}"
      INSTANCE_NAMESPACE = var.instance_namespace
      INSTANCE_NAME      = var.instance_name
      CNE_CRD_NAME       = var.cne_crd_name
      CONDITION_TIMEOUT  = tostring(var.condition_timeout_seconds)
      CRD_TIMEOUT        = tostring(var.crd_timeout_seconds)
      CRD_POLL_INTERVAL  = tostring(var.crd_poll_interval_seconds)
      POLL_INTERVAL      = tostring(var.poll_interval_seconds)
    }
    command = "bash '${path.module}/scripts/wait-cneinstance-ready.sh'"
  }
}
