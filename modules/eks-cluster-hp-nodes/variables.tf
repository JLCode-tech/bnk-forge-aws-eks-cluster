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
  description = "Starting subnet index for cidrsubnet() when auto-carving TMM-external subnets. Default 200 leaves clear of worker subnets at offsets 0..N."
  type        = number
  default     = 200
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
  description = "Starting subnet index for cidrsubnet() when auto-carving TMM-internal subnets. Default 210 sits 10 indices clear of the external default (200) so the two ranges never overlap."
  type        = number
  default     = 210
}

# =============================================================================
# Node group configuration
# =============================================================================

variable "instance_type" {
  description = "EC2 instance type for HP nodes. Default m5n.large (Intel Xeon + 100Gbps ENA + SR-IOV). For higher throughput: c5n.xlarge / m5n.xlarge / c6gn.xlarge. Note that 2 secondary ENIs are attached — the instance type must support at least 3 total ENIs (m5n.large supports 3, m5n.xlarge supports 4)."
  type        = string
  default     = "m5n.large"
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
  description = "Device index for the TMM-external secondary ENI. Default 2 → ens7 on AL2023, matching the ens7-ipvlan-l2 NetworkAttachmentDefinition default."
  type        = number
  default     = 2
}

variable "internal_eni_device_index" {
  description = "Device index for the TMM-internal secondary ENI. Default 3 → ens8 on AL2023, matching the ens8-ipvlan-l2 NetworkAttachmentDefinition default."
  type        = number
  default     = 3
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
