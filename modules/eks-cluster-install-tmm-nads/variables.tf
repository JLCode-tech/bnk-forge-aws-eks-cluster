# =============================================================================
# AWS credentials (Forge-resolved at deploy time; any auth method)
# =============================================================================
# Needed for the data.aws_subnets discovery that derives each NAD's static
# address from the matching f5-bnk-role-tagged subnet, rather than hardcoding
# 10.10.1.1/24. Mirrors the cneinstall module's pattern.

variable "aws_access_key_id" {
  type      = string
  sensitive = true
}

variable "aws_secret_access_key" {
  type      = string
  sensitive = true
}

variable "aws_session_token" {
  type      = string
  sensitive = true
  default   = ""
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  description = "EKS cluster VPC ID. Used to scope the tag-discovery query for the TMM-external and TMM-internal subnets. Auto-wired from cluster-register / cluster-create."
  type        = string
}

# =============================================================================
# Forge-injected kubeconfig
# =============================================================================
# local.forge_kubeconfig is injected at deploy time via a generated
# bnk_forge_providers.tf. Falls back to forge_kubeconfig_content for
# unit / local testing.

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

# =============================================================================
# NAD static-address overrides
# =============================================================================
# The CNI 'static' IPAM type requires at least one address per NAD. TMM
# doesn't actually use this for traffic — the F5 IPAM operator manages real
# allocation — but the schema needs *something*. By default we DERIVE the
# placeholder from the first f5-bnk-role-tagged subnet discovered in the
# cluster VPC, so the NAD is internally consistent with the network the ENI
# actually lives on.
#
# Set these explicitly only to override the derivation (or to use a custom
# address when discovery returns nothing — see the hardcoded fallback at the
# bottom of main.tf locals).

variable "nad_external_static_address" {
  description = "Override for the external NAD's static IPAM placeholder address (CIDR format, e.g. '10.10.1.1/24'). Empty = derive from the first discovered f5-bnk-role=tmm-external subnet."
  type        = string
  default     = ""
}

variable "nad_internal_static_address" {
  description = "Override for the internal NAD's static IPAM placeholder address. Empty = derive from the first discovered f5-bnk-role=tmm-internal subnet."
  type        = string
  default     = ""
}

variable "nad_static_address_fallback" {
  description = "Address used when discovery returns no tagged subnets AND no override is set. Default 10.10.1.1/24 matches the F5 install guide's reference value."
  type        = string
  default     = "10.10.1.1/24"
}
