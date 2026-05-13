variable "aws_access_key_id" {
  description = "AWS access key ID. Resolved by Forge's credential template at deploy time. Populated regardless of the template's auth method (access_keys / profile / sso) — Forge normalizes all three via boto3 before injecting."
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS secret access key. Resolved by Forge's credential template at deploy time. Populated regardless of auth method."
  type        = string
  sensitive   = true
}

variable "aws_session_token" {
  description = "AWS session token. Populated for STS-assumed-role, AWS SSO, and any profile that derives temporary credentials. Empty for long-lived IAM user keys."
  type        = string
  sensitive   = true
  default     = ""
}

variable "aws_region" {
  description = "AWS region where the existing EKS cluster resides. Typically supplied by the Forge project's region field."
  type        = string
}

variable "eks_cluster_name" {
  description = "Existing AWS EKS cluster name."
  type        = string
}
