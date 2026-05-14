# =============================================================================
# Forge-injected kubeconfig
# =============================================================================
# local.forge_kubeconfig is injected at deploy time via a generated
# bnk_forge_providers.tf. Falls back to forge_kubeconfig_content for
# unit / local testing.
# =============================================================================

variable "forge_kubeconfig_content" {
  description = "Plain-text kubeconfig used for kubectl applies. Forge overrides this at deploy time with a local.forge_kubeconfig reference; the variable default is the local-test fallback. Sensitive."
  type        = string
  sensitive   = true
  default     = ""
}

# =============================================================================
# Multus installation
# =============================================================================

variable "install_multus" {
  description = "When true, apply the upstream multus-daemonset manifest. AWS EKS does NOT ship Multus by default — TMM's secondary network attachments require it. Set false if your cluster already has Multus installed (some platforms do this via an addon)."
  type        = bool
  default     = true
}

variable "multus_version" {
  description = "Multus release tag to install. Default tracks a tested stable release. The full manifest URL is built as github.com/k8snetworkplumbingwg/multus-cni/<version>/deployments/multus-daemonset.yml."
  type        = string
  default     = "v4.1.0"
}

variable "multus_manifest_url" {
  description = "Explicit override for the multus-daemonset manifest URL. Empty = build from multus_version. Use this to pin a private mirror or vendored copy."
  type        = string
  default     = ""
}

# =============================================================================
# NetworkAttachmentDefinitions (external + internal)
# =============================================================================
# Match the F5 multi-node BNK on AWS/EKS install guide:
#   - ens7-ipvlan-l2 → external data plane (master ens7, IPVLAN L2)
#   - ens8-ipvlan-l2 → internal data plane (master ens8, IPVLAN L2)
# Names must match the cneinstall blueprint input `network_attachments`.

variable "nad_namespace" {
  description = "Namespace where the NADs are created. F5 install guide uses 'default'; CNEInstance also lives in 'default' by convention, so the NetworkAttachmentDefinition lookup is unambiguous."
  type        = string
  default     = "default"
}

variable "nad_external_name" {
  description = "NetworkAttachmentDefinition name for the external data plane. Must match the CNEInstance CR's networkAttachments entry."
  type        = string
  default     = "ens7-ipvlan-l2"
}

variable "nad_external_master" {
  description = "Host interface the external NAD binds to. Default 'ens7' matches the hp-nodes external_eni_device_index=2 → ens7 mapping on AL2023."
  type        = string
  default     = "ens7"
}

variable "nad_internal_name" {
  description = "NetworkAttachmentDefinition name for the internal data plane. Must match the CNEInstance CR's networkAttachments entry."
  type        = string
  default     = "ens8-ipvlan-l2"
}

variable "nad_internal_master" {
  description = "Host interface the internal NAD binds to. Default 'ens8' matches hp-nodes internal_eni_device_index=3 → ens8."
  type        = string
  default     = "ens8"
}

variable "nad_cni_type" {
  description = "Multus CNI plug-in type. F5 install guide uses 'ipvlan' for AWS; on-prem deploys may use 'host-device' or 'macvlan'."
  type        = string
  default     = "ipvlan"
}

variable "nad_ipvlan_mode" {
  description = "ipvlan mode. F5 reference uses 'l2'. Only used when nad_cni_type = ipvlan."
  type        = string
  default     = "l2"
}

variable "nad_static_address" {
  description = "Placeholder static IP set in the NAD ipam block. TMM doesn't actually use this for traffic — IPAM operator manages real allocation — but Multus + CNI plug-ins require a valid IPAM stanza. F5 reference uses 10.10.1.1/24. Leave default unless your cluster has a conflict."
  type        = string
  default     = "10.10.1.1/24"
}
