# =============================================================================
# AWS credentials (Forge-resolved at deploy time; any auth method)
# =============================================================================
# Passed to the discovery script so it can DescribeNetworkInterfaces /
# AssignPrivateIpAddresses on the TMM secondary ENIs and refresh its kubeconfig
# via `aws eks update-kubeconfig`.

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

variable "eks_cluster_name" {
  description = "EKS cluster name. The discovery script refreshes an exec-auth kubeconfig via `aws eks update-kubeconfig --name <this>` (avoids the F12 stale-token). Auto-wired from cluster-create / cluster-register."
  type        = string
}

variable "vpc_id" {
  description = "EKS cluster VPC ID. Retained for blueprint wiring parity; the discovery script scopes ENI lookups by attachment.instance-id + the f5-bnk:tmm-role tag rather than by VPC. Auto-wired from cluster-create / cluster-register."
  type        = string
  default     = ""
}

# =============================================================================
# Forge-injected kubeconfig (fallback only)
# =============================================================================
# The discovery script generates its own fresh kubeconfig via `aws eks
# update-kubeconfig`; this is retained for parity / standalone runs.

variable "forge_kubeconfig_content" {
  description = "Plain-text kubeconfig. Forge overrides this at deploy time; unused by the discovery script (which refreshes its own). Sensitive."
  type        = string
  sensitive   = true
  default     = ""
}

# =============================================================================
# Upstream gate
# =============================================================================

variable "multus_ready" {
  description = "Gate from eks-cluster-install-multus. Must be true (Multus installed, NAD CRD Established) before host-device NADs are applied. Auto-wired from install-multus.multus_ready."
  type        = bool
  default     = false
}

# =============================================================================
# Host-device NADs
# =============================================================================

variable "nad_namespace" {
  description = "Namespace where the NADs are created (in addition to `default`). MUST match the CNEInstance namespace — the CNE reconciler resolves NetworkAttachmentDefinitions by name within it. Gold-standard split: f5-cne-system."
  type        = string
  default     = "f5-cne-system"
}

variable "nad_external_name" {
  description = "External (client-facing) host-device NAD name. Must match cneinstall's network_attachments[0]. awsbnkctl uses external-netdevice."
  type        = string
  default     = "external-netdevice"
}

variable "nad_internal_name" {
  description = "Internal (backend) host-device NAD name. Must match cneinstall's network_attachments[1]. awsbnkctl uses internal-netdevice."
  type        = string
  default     = "internal-netdevice"
}

# =============================================================================
# SelfIP + iface-discovery tuning
# =============================================================================

variable "selfip_host_offset" {
  description = "Host octet for the TMM SelfIP within each /24 TMM subnet (awsbnkctl uses .240). The discovery script assigns <subnet>.<offset> as a secondary private IP on each ENI and surfaces it for the F5SPKVlan."
  type        = number
  default     = 240
}

variable "skip_iface_discovery" {
  description = "When true, skip the privileged iface-discovery probe pod and use the deterministic device-index fallback (ens8/0000:00:08.0 ext, ens7/0000:00:07.0 int — proven on c5n.4xlarge/AL2023). Default false: run discovery for robustness across instance types."
  type        = bool
  default     = false
}

variable "external_pci_fallback" {
  description = "Fallback external PCI bus id when iface-discovery is skipped/unavailable. Deterministic on c5n.4xlarge/AL2023 (ens8 → 0000:00:08.0)."
  type        = string
  default     = "0000:00:08.0"
}

variable "internal_pci_fallback" {
  description = "Fallback internal PCI bus id (ens7 → 0000:00:07.0)."
  type        = string
  default     = "0000:00:07.0"
}

variable "external_ifname_fallback" {
  description = "Fallback external Linux ifname (device-index 3 → ens8)."
  type        = string
  default     = "ens8"
}

variable "internal_ifname_fallback" {
  description = "Fallback internal Linux ifname (device-index 2 → ens7)."
  type        = string
  default     = "ens7"
}
