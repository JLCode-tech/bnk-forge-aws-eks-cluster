# =============================================================================
# Forge-injected kubeconfig
# =============================================================================
# local.forge_kubeconfig is injected at deploy time via a generated
# bnk_forge_providers.tf. Falls back to forge_kubeconfig_content for
# unit / local testing.

variable "forge_kubeconfig_content" {
  description = "Plain-text kubeconfig used for kubectl applies. Forge overrides this at deploy time with a local.forge_kubeconfig reference. Sensitive."
  type        = string
  sensitive   = true
  default     = ""
}

# =============================================================================
# Multus installation
# =============================================================================

variable "install_multus" {
  description = "When true, apply the upstream multus-daemonset manifest. Set false to skip if your cluster already has Multus from another source."
  type        = bool
  default     = true
}

variable "multus_version" {
  description = "Multus release tag. The full manifest URL is built as github.com/k8snetworkplumbingwg/multus-cni/<version>/deployments/multus-daemonset.yml. Default tracks the most recent stable release at module-publish time."
  type        = string
  default     = "v4.2.4"
}

variable "multus_manifest_url" {
  description = "Explicit override for the multus-daemonset manifest URL. Empty = build from multus_version. Use this to pin a private mirror or vendored copy."
  type        = string
  default     = ""
}

variable "multus_crd_wait_timeout" {
  description = "Timeout (kubectl wait format) for the NetworkAttachmentDefinition CRD to be Established after manifest apply."
  type        = string
  default     = "120s"
}

variable "multus_rollout_wait_timeout" {
  description = "Timeout for the kube-multus-ds DaemonSet rollout."
  type        = string
  default     = "180s"
}
