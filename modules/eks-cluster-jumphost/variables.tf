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
# Cluster identity
# =============================================================================

variable "eks_cluster_name" {
  description = "Name of the EKS cluster the jumphost will be configured to access. Used for naming, tagging, and the update-kubeconfig helper."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the jumphost security group and instance are placed. Must be the same VPC as the EKS cluster."
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs. The jumphost is placed in the first subnet (index 0). Must be in the same VPC as the cluster and have a route to the internet gateway (for the EIP)."
  type        = list(string)
}

# =============================================================================
# Access control
# =============================================================================

variable "user_ip" {
  description = "Operator source IP in CIDR /32 notation (e.g. 203.0.113.1/32). Used to lock SSH inbound to this address only. A wrong value strands SSH access but the instance remains reachable via the private endpoint and SSM Session Manager."
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}/32$", var.user_ip))
    error_message = "user_ip must be a single IPv4 address in /32 CIDR notation (e.g. 203.0.113.1/32)."
  }
}

# =============================================================================
# Instance configuration
# =============================================================================

variable "jumphost_instance_type" {
  description = "EC2 instance type for the jumphost. t3.medium is sufficient for kubectl + aws CLI usage."
  type        = string
  default     = "t3.medium"
}

variable "jumphost_volume_size" {
  description = "Root EBS volume size in GiB for the jumphost instance."
  type        = number
  default     = 20

  validation {
    condition     = var.jumphost_volume_size >= 8 && var.jumphost_volume_size <= 100
    error_message = "jumphost_volume_size must be between 8 and 100 GiB."
  }
}

variable "kubectl_version" {
  description = "kubectl version to install on the jumphost (e.g. 1.32.0). Should match the cluster's Kubernetes minor version."
  type        = string
  default     = "1.32.0"
}

# =============================================================================
# Tagging
# =============================================================================

variable "tags" {
  description = "Additional tags applied to all created resources."
  type        = map(string)
  default     = {}
}
