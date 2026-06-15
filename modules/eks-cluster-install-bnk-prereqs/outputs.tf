# k8s/bnk-prerequisites/outputs.tf
# BNK Prerequisites Module Outputs

# =============================================================================
# NAMESPACE OUTPUTS
# =============================================================================

output "operator_namespace" {
  description = "Name of the operator namespace (FLO, License CR, OTEL/CWC). Gold-standard: f5-cne-core."
  value       = kubernetes_namespace_v1.operator.metadata[0].name
}

output "instance_namespace" {
  description = "Name of the instance namespace (CNEInstance CR, cloud-network CM, NADs, IRSA SA, CNE controller). Gold-standard: f5-cne-system. Falls back to operator_namespace when instance_namespace is empty (legacy single-namespace mode)."
  value       = var.instance_namespace != "" ? var.instance_namespace : var.operator_namespace
}

output "utils_namespace" {
  description = "Name of the utilities namespace"
  value       = kubernetes_namespace_v1.utils.metadata[0].name
}

output "gateway_namespace" {
  description = "Name of the gateway namespace"
  value       = kubernetes_namespace_v1.gateway.metadata[0].name
}

# =============================================================================
# FAR SECRET OUTPUTS
# =============================================================================

output "far_secret_name" {
  description = "Name of the FAR image pull secret (always 'far-secret')"
  value       = "far-secret"
}

# =============================================================================
# VERSION OUTPUTS (from manifest parsing)
# =============================================================================

output "flo_version" {
  description = "FLO Helm chart version parsed from manifest"
  value       = lookup(data.external.component_versions.result, "flo", "")
}

output "manifest_version" {
  description = "BNK manifest version used"
  value       = var.bnk_manifest_version
}

output "component_versions" {
  description = "All component versions parsed from manifest"
  value       = data.external.component_versions.result
}

output "cert_manager_version" {
  description = "F5 cert-manager version from manifest (informational — cert-manager module uses its own version)"
  value       = lookup(data.external.component_versions.result, "cert_manager", "")
}

# =============================================================================
# DEPENDENCY GATE
# =============================================================================

output "prerequisites_ready" {
  description = "Boolean gate — true when namespaces, secrets, and manifest are all ready"
  value       = true

  depends_on = [
    kubernetes_namespace_v1.operator,
    kubernetes_namespace_v1.utils,
    kubernetes_namespace_v1.gateway,
    kubernetes_secret_v1.far_secret_operator,
    kubernetes_secret_v1.far_secret_utils,
    kubernetes_secret_v1.far_secret_gateway,
    data.external.component_versions,
  ]
}
