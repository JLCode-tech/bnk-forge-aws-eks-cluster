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
# hugepages DaemonSet
# =============================================================================

variable "install_hugepages" {
  description = "When true, apply the hugepages-setup DaemonSet. Set false to skip if hugepages are already configured on the cluster's BNK nodes."
  type        = bool
  default     = true
}

variable "daemonset_rollout_timeout" {
  description = "Timeout (kubectl rollout status format) for the hugepages-setup DaemonSet to be Ready on all role=bnk nodes. F5 requires kubelet to advertise hugepages-2Mi capacity before TMM can schedule. Matches awsbnkctl Phase 11b hugepagesReadyTimeout=5m."
  type        = string
  default     = "300s"
}
