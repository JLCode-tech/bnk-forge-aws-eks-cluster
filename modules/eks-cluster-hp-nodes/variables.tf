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
  description = "VPC ID where TMM subnets will be created (must match the cluster's VPC)."
  type        = string
}

variable "vpc_cidr" {
  description = "Primary CIDR block of the cluster VPC. Used to auto-carve TMM subnet CIDRs when tmm_subnet_cidrs is empty."
  type        = string
}

variable "availability_zones" {
  description = "AZ names to place HP nodes + TMM subnets in. Should match the cluster's AZ spread."
  type        = list(string)
}

variable "node_subnet_ids" {
  description = "Existing cluster subnet IDs where the HP managed node group places its PRIMARY ENI (so nodes can reach the control plane). Typically this is the cluster's existing private subnets. For brownfield (cluster-register) auto-wiring this comes from the cluster's vpc_config.subnet_ids — pass the cluster's private subnets if you want to avoid placing HP nodes on public subnets. The secondary ENI lands in a TMM subnet via user-data."
  type        = list(string)
}

# =============================================================================
# TMM subnet configuration
# =============================================================================

variable "tmm_subnet_cidrs" {
  description = "Explicit list of TMM subnet CIDRs (one per AZ). Empty list = auto-carve from vpc_cidr using cidrsubnet(). For a /16 VPC and default tmm_subnet_newbits=8, you'll get /24 subnets starting at offset 200 (well clear of the typical /24 worker subnets at offsets 0-2)."
  type        = list(string)
  default     = []
}

variable "tmm_subnet_newbits" {
  description = "Bits added to vpc_cidr when auto-carving TMM subnets via cidrsubnet(). Default 8 → /24 subnets from a /16 VPC."
  type        = number
  default     = 8
}

variable "tmm_subnet_index_offset" {
  description = "Starting subnet index for cidrsubnet() when auto-carving. Default 200 leaves room for worker subnets at offsets 0..N. Per AZ i, the carved CIDR is cidrsubnet(vpc_cidr, tmm_subnet_newbits, tmm_subnet_index_offset + i)."
  type        = number
  default     = 200
}

# =============================================================================
# Node group configuration
# =============================================================================

variable "instance_type" {
  description = "EC2 instance type for HP nodes. Defaults to m5n.large (Intel Xeon Scalable + 100Gbps ENA + SR-IOV) — enough for a small TMM data plane. For higher throughput use c5n.xlarge / m5n.xlarge / c6gn.xlarge."
  type        = string
  default     = "m5n.large"
}

variable "node_count_per_az" {
  description = "Desired HP nodes per AZ. Total HP nodes = this × length(availability_zones). Set 0 to disable the HP node group entirely (subnets are still created if tag_subnets_for_tmm = true)."
  type        = number
  default     = 1
}

variable "node_disk_size_gb" {
  description = "Root volume size for HP nodes."
  type        = number
  default     = 50
}

variable "eks_ami_release_version" {
  description = "EKS-optimized AMI release version (e.g. '1.30.0-20240625'). Empty = pinned-latest for the cluster's K8s minor version."
  type        = string
  default     = ""
}

variable "node_label_app" {
  description = "Value for the 'app' label applied to HP nodes — FLO uses this to schedule TMM pods."
  type        = string
  default     = "f5-tmm"
}

variable "node_taints" {
  description = "Taints applied to HP nodes. Default empty = HP nodes accept any pod (TMM lands here only because of the app=f5-tmm label match). Add taints to dedicate the pool: e.g. [{ key = 'role', value = 'tmm', effect = 'NO_SCHEDULE' }]."
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

# =============================================================================
# Secondary ENI configuration (the data-plane interface TMM uses)
# =============================================================================

variable "secondary_eni_device_index" {
  description = "Device index for the secondary ENI attached by user-data. AWS conventionally numbers ENIs as ens5 (primary), then ens6/ens7/... by device_index. The F5 reference flow uses device_index=2 → ens7, which matches the NetworkAttachmentDefinition's 'master: ens7' default."
  type        = number
  default     = 2
}

variable "additional_ips_per_eni" {
  description = "Number of additional private IPs to allocate on the secondary ENI at creation time. The F5 reference flow allocates one per TMM replica for VLAN CR assignment. Default 0 = let cneinstall's IPAM operator manage allocation."
  type        = number
  default     = 0
}

# =============================================================================
# Tagging
# =============================================================================

variable "tag_subnets_for_tmm" {
  description = "Tag the created TMM subnets with 'f5-bnk-role=tmm-external' so cneinstall auto-builds the BNKGateway CR's defaultListenerNetworks. Leave true unless you want to skip Gateway-API translation."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to all created resources."
  type        = map(string)
  default     = {}
}
