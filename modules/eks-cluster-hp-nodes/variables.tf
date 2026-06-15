# =============================================================================
# AWS credentials (Forge-resolved at deploy time; any auth method)
# =============================================================================

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

# =============================================================================
# Cluster identity (auto-wired from cluster-register or cluster-create)
# =============================================================================

variable "eks_cluster_name" {
  description = "Name of the EKS cluster the HP node group attaches to."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where TMM subnets are created (must match the cluster's VPC)."
  type        = string
}

variable "vpc_cidr" {
  description = "Primary CIDR block of the cluster VPC. Used to auto-carve TMM subnet CIDRs when explicit *_subnet_cidrs lists are empty."
  type        = string
}

variable "availability_zones" {
  description = "AZ names to spread HP nodes + TMM subnets across. Should match the cluster's AZ spread."
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Existing cluster subnet IDs where the HP managed node group places its PRIMARY ENI (so nodes can reach the control plane). Typically the cluster's existing private subnets. The TMM secondary ENIs (external + internal) land in separate dedicated subnets via user-data."
  type        = list(string)
}

# =============================================================================
# TMM EXTERNAL subnet — client-facing data plane (ens7)
# =============================================================================

variable "tmm_external_subnet_cidrs" {
  description = "Explicit list of TMM-external subnet CIDRs (one per AZ). Empty list = auto-carve from vpc_cidr using cidrsubnet()."
  type        = list(string)
  default     = []
}

variable "tmm_external_subnet_newbits" {
  description = "Bits added to vpc_cidr when auto-carving TMM-external subnets. Default 8 → /24 subnets from a /16 VPC."
  type        = number
  default     = 8
}

variable "tmm_external_subnet_index_offset" {
  description = "Starting subnet index for cidrsubnet() when auto-carving TMM-external subnets. Default 200 leaves clear of worker subnets at offsets 0..N. NOTE: offset + AZ count must fit within 2^newbits — fine for /16 VPC with default newbits=8 (256 slots), but a /20 VPC only has 16 slots and would error. Override explicitly via tmm_external_subnet_cidrs if your VPC is tight."
  type        = number
  default     = 200

  validation {
    condition     = var.tmm_external_subnet_index_offset >= 0 && var.tmm_external_subnet_index_offset < pow(2, var.tmm_external_subnet_newbits)
    error_message = "tmm_external_subnet_index_offset must be in [0, 2^tmm_external_subnet_newbits). Reduce the offset (or set tmm_external_subnet_cidrs explicitly) when using a small VPC + large newbits."
  }
}

# =============================================================================
# TMM INTERNAL subnet — backend/origin data plane (ens8)
# =============================================================================

variable "tmm_internal_subnet_cidrs" {
  description = "Explicit list of TMM-internal subnet CIDRs (one per AZ). Empty list = auto-carve from vpc_cidr."
  type        = list(string)
  default     = []
}

variable "tmm_internal_subnet_newbits" {
  description = "Bits added to vpc_cidr when auto-carving TMM-internal subnets. Default 8 → /24 subnets from a /16 VPC."
  type        = number
  default     = 8
}

variable "tmm_internal_subnet_index_offset" {
  description = "Starting subnet index for cidrsubnet() when auto-carving TMM-internal subnets. Default 210 sits 10 indices clear of the external default (200) so the two ranges never overlap. Must fit within 2^tmm_internal_subnet_newbits (256 slots at default newbits=8) — override via tmm_internal_subnet_cidrs for small VPCs."
  type        = number
  default     = 210

  validation {
    condition     = var.tmm_internal_subnet_index_offset >= 0 && var.tmm_internal_subnet_index_offset < pow(2, var.tmm_internal_subnet_newbits)
    error_message = "tmm_internal_subnet_index_offset must be in [0, 2^tmm_internal_subnet_newbits)."
  }
}

# =============================================================================
# Node group configuration
# =============================================================================

variable "instance_type" {
  description = "EC2 instance type for HP nodes. Default c5n.xlarge (Intel Xeon + 100Gbps ENA + SR-IOV, 4 ENIs, available in all major regions). For higher throughput: m5n.xlarge / m6in.xlarge. Note: m5n family is absent in some regions (e.g. ap-southeast-2) — use c5n.xlarge or m6i.xlarge for broad compatibility. The instance type must support at least 3 total ENIs (2 secondary ENIs are attached for TMM external + internal)."
  type        = string
  default     = "c5n.xlarge"
}

variable "node_count_per_az" {
  description = "Desired HP nodes per AZ. Total HP nodes = this × length(availability_zones). Set 0 to skip the node group entirely (subnets are still created if tag_subnets_for_tmm = true)."
  type        = number
  default     = 1
}

variable "node_disk_size_gb" {
  description = "Root volume size for HP nodes."
  type        = number
  default     = 50
}

variable "eks_ami_release_version" {
  description = "EKS-optimized AMI release version. Empty = pinned-latest for the cluster's K8s minor version."
  type        = string
  default     = ""
}

variable "node_label_app" {
  description = "Value for the 'app' label applied to HP nodes — FLO uses this to schedule TMM pods."
  type        = string
  default     = "f5-tmm"
}

variable "node_taints" {
  description = "Taints applied to HP nodes. Default empty. Add taints to dedicate the pool: e.g. [{ key = 'role', value = 'tmm', effect = 'NO_SCHEDULE' }]."
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

# =============================================================================
# Secondary ENI configuration (3-interface TMM model)
# =============================================================================
# TMM pods get THREE interfaces:
#   1. CNI primary (managed by VPC CNI on ens5 — the node's primary ENI)
#   2. External data plane (ens7 by default — secondary ENI on TMM-external)
#   3. Internal data plane (ens8 by default — secondary ENI on TMM-internal)
#
# AL2023 names ENIs by device index: device_index=0 → ens5, 1 → ens6, 2 → ens7,
# 3 → ens8. The defaults below match the F5 reference NetworkAttachmentDefinition
# names: ens7-ipvlan-l2 (external) and ens8-ipvlan-l2 (internal).

variable "external_eni_device_index" {
  description = "Device index for the TMM-external (client-facing) secondary ENI. Default 3 → ens8 on AL2023, matching awsbnkctl phase17 (EXTERNAL_ENI device-index 3 → ens8 → EXTERNAL_PCI 0000:00:08.0). The host-device NAD discovers the real PCI by MAC at runtime; this index fixes the deterministic ens8 placement the gold standard proves Active."
  type        = number
  default     = 3
}

variable "internal_eni_device_index" {
  description = "Device index for the TMM-internal (backend-facing) secondary ENI. Default 2 → ens7 on AL2023, matching awsbnkctl phase17 (INTERNAL_ENI device-index 2 → ens7 → INTERNAL_PCI 0000:00:07.0)."
  type        = number
  default     = 2
}

variable "single_az_demo" {
  description = "When true (default), pin the HP node group + TMM ext/int subnets to a SINGLE AZ (availability_zones[0]) so there is exactly ONE role=bnk TMM node. Matches awsbnkctl's single-TMM demo (phase16 labels the first role=bnk node) and makes the downstream iface-discovery + SelfIP assignment unambiguous. Set false for a per-AZ multi-TMM HA topology (not yet validated end-to-end for host-device)."
  type        = bool
  default     = true
}

variable "additional_ips_per_eni" {
  description = "Number of additional private IPs allocated on EACH secondary ENI at creation time. 0 = let cneinstall's IPAM operator manage allocation."
  type        = number
  default     = 0
}

# =============================================================================
# Tagging
# =============================================================================

variable "tag_subnets_for_tmm" {
  description = "Tag the created TMM-external subnets with 'f5-bnk-role=tmm-external' (for cneinstall auto-discovery of BNKGateway listener networks) and TMM-internal subnets with 'f5-bnk-role=tmm-internal'."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to all created resources."
  type        = map(string)
  default     = {}
}
