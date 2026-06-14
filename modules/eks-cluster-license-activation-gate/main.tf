# =============================================================================
# license-activation-gate
# =============================================================================
# Cloud-agnostic primitive: apply the BNK License CR, then honestly gate on
# activation.
#
# FLO's Helm `license.*` values configure the license controller / TEEM
# verification material — they do NOT materialise a `License` CR. Nothing in
# the forge per-cloud catalogs applies one either. So a forge BNK deploy hands
# the JWT to FLO but never creates a License object and never verifies that the
# operator activated it: the classic D-017 "HTTP 200 != operation success" bug,
# baked into the blueprint.
#
# awsbnkctl (the gold standard) applies the CR itself in phase23 (server-side
# apply after the CRD registers) and then gates on .status.state == "Active" in
# phase25. This module ports that apply-then-gate contract.
#
# This module runs scripts/wait-license-active.sh, which:
#   1. waits for the License CRD to be registered (pre-gate; FLO installs it),
#   2. server-side-applies the rendered License CR (JWT inlined from an env var
#      into a 0600 temp manifest, never written to Terraform state or logs), and
#   3. polls the named License until .status.state == "Active", and
#   4. on timeout dumps pod diagnostics and exits 1 so Terraform fails closed.
#
# Cloud-agnostic by design: the License CR + operator .status are identical on
# every cloud. Per-cloud catalogs vendor this and call it as a sub-module after
# their cneinstance readiness gate, passing their own namespace + JWT.

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

  # Render the License CR with a placeholder where the JWT goes. The real JWT
  # is NOT interpolated here — keeping it out of this string keeps it out of
  # Terraform plan/state. wait-license-active.sh substitutes __JWT__ from the
  # LICENSE_JWT env var into a 0600 temp file at apply time.
  license_manifest = templatefile("${path.module}/manifests/license.yaml.tftpl", {
    license_name            = var.license_name
    license_namespace       = var.license_namespace
    operation_mode          = var.operation_mode
    jwt_placeholder         = "__JWT__"
    teem_cert_url           = var.teem_cert_url
    teem_entitlement_url    = var.teem_entitlement_url
    teem_initial_config_url = var.teem_initial_config_url
  })
}

resource "null_resource" "license_gate" {
  triggers = {
    namespace          = var.license_namespace
    name               = var.license_name
    crd                = var.license_crd_name
    operation_mode     = var.operation_mode
    activation_timeout = tostring(var.activation_timeout_seconds)
    crd_timeout        = tostring(var.crd_timeout_seconds)
    crd_poll_interval  = tostring(var.crd_poll_interval_seconds)
    poll_interval      = tostring(var.poll_interval_seconds)
    kubeconfig_file    = local.kubeconfig_path
    # Re-run when the rendered CR (sans JWT) or the JWT itself changes.
    manifest_hash = sha256(local.license_manifest)
    jwt_hash      = sha256(var.jwt_token)
    script_hash   = filesha256("${path.module}/scripts/wait-license-active.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      KUBECTL            = "kubectl --kubeconfig ${local.kubeconfig_path}"
      LICENSE_NAMESPACE  = var.license_namespace
      LICENSE_NAME       = var.license_name
      LICENSE_CRD_NAME   = var.license_crd_name
      LICENSE_MANIFEST   = local.license_manifest
      LICENSE_JWT        = var.jwt_token
      ACTIVATION_TIMEOUT = tostring(var.activation_timeout_seconds)
      CRD_TIMEOUT        = tostring(var.crd_timeout_seconds)
      CRD_POLL_INTERVAL  = tostring(var.crd_poll_interval_seconds)
      POLL_INTERVAL      = tostring(var.poll_interval_seconds)
    }
    command = "bash '${path.module}/scripts/wait-license-active.sh'"
  }
}
