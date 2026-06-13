# =============================================================================
# Forge-injected kubeconfig (fallback path)
# =============================================================================
# When the caller does not pass an explicit kubeconfig_file path, this module
# materialises one from local.forge_kubeconfig (injected by Forge at deploy
# time via a generated bnk_forge_providers.tf) or from forge_kubeconfig_content
# for standalone / unit runs.

variable "forge_kubeconfig_content" {
  description = "Kubeconfig YAML content. Used only when kubeconfig_file is empty. Auto-injected by Forge."
  type        = string
  sensitive   = true
  default     = ""
}

variable "kubeconfig_file" {
  description = "Path to an existing kubeconfig file. Pass the wrapper module's local_sensitive_file.kubeconfig.filename so both share one materialised kubeconfig. Empty = this module materialises its own from forge_kubeconfig_content."
  type        = string
  default     = ""
}

# =============================================================================
# CNEInstance identity (wired from the cneinstall step)
# =============================================================================

variable "instance_namespace" {
  description = "Namespace where the CNEInstance CR lives. On the forge EKS module this is var.operator_namespace (default f5-operator) — NOT awsbnkctl's f5-cne-system."
  type        = string
}

variable "instance_name" {
  description = "Name of the CNEInstance CR to poll."
  type        = string
}

variable "cne_crd_name" {
  description = "Fully-qualified CNEInstance CRD name used by the CRD pre-gate."
  type        = string
  default     = "cneinstances.k8s.f5.com"
}

# =============================================================================
# Gate tuning
# =============================================================================

variable "condition_timeout_seconds" {
  description = "Max seconds to wait for F5TmmAvailable && CNEControllerAvailable (or the state fallback) before failing closed. Mirrors awsbnkctl phase25's ~9 min cap."
  type        = number
  default     = 570
}

variable "crd_timeout_seconds" {
  description = "Max seconds to wait for the CNEInstance CRD to be registered before the condition poll begins."
  type        = number
  default     = 300
}

variable "crd_poll_interval_seconds" {
  description = "Seconds between CRD pre-gate poll iterations."
  type        = number
  default     = 5
}

variable "poll_interval_seconds" {
  description = "Seconds between condition-gate poll iterations."
  type        = number
  default     = 30
}
