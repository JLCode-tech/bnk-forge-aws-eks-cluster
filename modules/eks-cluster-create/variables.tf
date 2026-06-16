# =============================================================================
# AWS credentials (any Forge auth method — resolved by Forge at deploy time)
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
# Cluster identity
# =============================================================================

variable "eks_cluster_name" {
  description = "Name for the new EKS cluster. Also used as a prefix for VPC, subnet, IAM role names."
  type        = string
}

variable "eks_cluster_version" {
  description = "EKS Kubernetes minor version (e.g. '1.30'). Empty = latest available."
  type        = string
  default     = ""
}

variable "endpoint_public_access_cidrs" {
  description = "Source CIDRs allowed to reach the EKS public API endpoint. Defaults to 0.0.0.0/0 (open — required so Forge can reach the API from a variable NAT egress IP). HARDENING: set this to the operator/Forge egress + jumphost CIDRs to lock the public endpoint down. The private endpoint is always enabled, so in-VPC access is unaffected. See ledger D-031 SECURITY NOTE."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# =============================================================================
# Network configuration
# =============================================================================

variable "vpc_cidr" {
  description = "CIDR block for the new VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "AZ names to use. Empty list = first 3 AZs in the region."
  type        = list(string)
  default     = []
}

variable "private_subnet_newbits" {
  description = "How many bits to add when carving private subnets from vpc_cidr via cidrsubnet(). 8 bits → /24 subnets from a /16 VPC."
  type        = number
  default     = 8
}

variable "public_subnet_newbits" {
  description = "How many bits to add when carving public subnets. Default places public after private."
  type        = number
  default     = 8
}

# =============================================================================
# Node group configuration
# =============================================================================

variable "worker_instance_type" {
  description = "EC2 instance type for the EKS managed node group."
  type        = string
  default     = "m5.large"
}

variable "worker_count_per_az" {
  description = "Desired worker nodes per AZ. Total nodes = this × availability_zone_count."
  type        = number
  default     = 1
}

variable "worker_disk_size_gb" {
  description = "Worker node root volume size."
  type        = number
  default     = 50
}

# =============================================================================
# Tagging for catalog discovery
# =============================================================================

variable "tag_private_subnets_for_tmm" {
  description = "When true, tag private subnets with 'f5-bnk-role=tmm-external' so the cluster-create outputs (and downstream cneinstall) can auto-discover them for the BNKGateway CR's defaultListenerNetworks."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to all created resources."
  type        = map(string)
  default     = {}
}
