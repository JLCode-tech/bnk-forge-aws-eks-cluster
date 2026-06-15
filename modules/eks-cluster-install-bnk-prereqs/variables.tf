# k8s/bnk-prerequisites/variables.tf
# BNK Prerequisites Module Variables

# =============================================================================
# PLATFORM KUBECONFIG (injected by BNK-Forge or set manually)
# =============================================================================

variable "forge_kubeconfig_content" {
  description = "Kubeconfig YAML content. Automatically injected by BNK-Forge for any platform (EKS, AKS, GKE, OCP, generic). Set manually for standalone usage."
  type        = string
  default     = ""
  sensitive   = true
}

# =============================================================================
# REQUIRED — Injected as Project Secret
# =============================================================================

variable "cne_pull_secret" {
  description = <<-EOT
    F5 FAR registry credentials. Accepts TWO formats:
    Format A: Base64-encoded JSON service account key from F5 (bare key).
    Format B: Base64-encoded dockerconfigjson ({"auths":{"repo.f5.com":{"auth":"..."}}}).
    Both are auto-detected. Injected as a project secret.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.cne_pull_secret) > 0
    error_message = "cne_pull_secret must not be empty. Configure it as a project secret."
  }
}

# =============================================================================
# NAMESPACE CONFIGURATION
# =============================================================================

variable "operator_namespace" {
  description = "Operator namespace — FLO (lifecycle operator), License CR, OTEL/CWC. Gold-standard split: f5-cne-core (awsbnkctl OperatorNamespace). The CNEInstance + CNE controller live in instance_namespace, NOT here."
  type        = string
  default     = "f5-cne-core"
}

variable "utils_namespace" {
  description = "Namespace for utility components (IPAM if deployed separately)"
  type        = string
  default     = "f5-utils"
}

variable "gateway_namespace" {
  description = "Namespace for Gateway API resources (Gateway, HTTPRoute, etc.)"
  type        = string
  default     = "bnk-gw"
}

variable "instance_namespace" {
  description = "Instance namespace — CNEInstance CR, cloud-network CM, NADs, IRSA SA, and the FLO-deployed CNE controller live here. Gold-standard split: f5-cne-system (awsbnkctl bnkconst.InstanceNamespace). When set and different from operator_namespace, creates this namespace + a far-secret here. Set empty to collapse onto operator_namespace (legacy single-namespace mode)."
  type        = string
  default     = "f5-cne-system"
}

# =============================================================================
# BNK MANIFEST VERSION
# =============================================================================

variable "bnk_manifest_version" {
  description = "BNK manifest version to download from FAR (e.g., 2.3.0-3.2598.3-0.0.170)"
  type        = string
  default     = "2.3.0-3.2598.3-0.0.170"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-", var.bnk_manifest_version))
    error_message = "BNK manifest version must start with X.Y.Z- format"
  }
}

# =============================================================================
# CLUSTER IDENTIFICATION (auto-wired)
# =============================================================================

variable "cluster_name" {
  description = "Name of the Kubernetes cluster (auto-wired from EKS module)"
  type        = string
  default     = ""
}
