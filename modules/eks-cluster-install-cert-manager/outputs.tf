# k8s/cert-manager/outputs.tf
# Jetstack cert-manager outputs for BNK 2.2 GA

output "release_name" {
  description = "Name of the Helm release"
  value       = helm_release.cert_manager.name
}

output "release_status" {
  description = "Status of the Helm release"
  value       = helm_release.cert_manager.status
}

output "namespace" {
  description = "Namespace where cert-manager is deployed"
  value       = helm_release.cert_manager.namespace
}

output "chart_version" {
  description = "Version of the deployed cert-manager chart"
  value       = helm_release.cert_manager.version
}

output "cert_manager_ready" {
  description = "Indicates cert-manager deployment is complete and ClusterIssuers are created"
  value       = true
  depends_on  = [null_resource.ensure_cluster_issuers]
}

# =============================================================================
# CLUSTER ISSUER OUTPUTS
# =============================================================================
# These are used by FLO and CNEInstance configuration

output "cluster_issuer_name" {
  description = "Name of the CA ClusterIssuer for BNK certificates (use in FLO flo-values.yaml and CNEInstance)"
  value       = var.create_cluster_issuer ? var.cluster_issuer_name : ""
  depends_on  = [null_resource.ensure_cluster_issuers]
}

output "ca_secret_name" {
  description = "Name of the CA certificate secret"
  value       = var.create_cluster_issuer ? var.ca_certificate_name : ""
  depends_on  = [null_resource.ensure_cluster_issuers]
}

output "webhook_service_name" {
  description = "Name of the cert-manager webhook service"
  value       = "${var.release_name}-webhook"
}

# =============================================================================
# OTEL CERTIFICATE OUTPUTS
# =============================================================================
# NOTE: CWC certs are auto-managed by FLO (tls-spkcwc-*, tls-csmqkview-*).
# Only OTEL certs need explicit creation — FLO embeds a static non-rotating cert.

output "otel_server_cert_secret_name" {
  description = "Name of the OTEL server certificate secret (managed by cert-manager, replaces static FLO Helm cert)"
  value       = var.create_otel_certs ? "external-otelsvr-secret" : ""
}

output "otel_f5ing_server_cert_secret_name" {
  description = "Name of the OTEL F5 Ingress server certificate secret (managed by cert-manager)"
  value       = var.create_otel_certs ? "external-f5ingotelsvr-secret" : ""
}

output "bnk_certs_ready" {
  description = "Indicates OTEL certificates have been issued by cert-manager (CWC certs are auto-managed by FLO)"
  value       = true
  depends_on  = [null_resource.ensure_otel_certificates]
}
