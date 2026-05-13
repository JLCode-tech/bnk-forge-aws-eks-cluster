variable "aws_access_key_id" {
  description = "AWS access key ID for discovering the existing EKS cluster."
  type        = string
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "AWS secret access key for discovering the existing EKS cluster."
  type        = string
  sensitive   = true
}

variable "aws_session_token" {
  description = "AWS session token (only required for STS-assumed-role credentials). Leave empty for static IAM user keys."
  type        = string
  sensitive   = true
  default     = ""
}

variable "aws_region" {
  description = "AWS region where the existing EKS cluster resides."
  type        = string
}

variable "eks_cluster_name" {
  description = "Existing AWS EKS cluster name."
  type        = string
}
