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
  description = "EKS cluster name. The heal script refreshes an exec-auth kubeconfig via aws eks update-kubeconfig. Auto-wired from cluster-create / cluster-register."
  type        = string
}

variable "operator_namespace" {
  description = "Operator namespace (cwc lives here). Gold-standard split: f5-cne-core. Auto-wired from bnk-prereqs.operator_namespace."
  type        = string
  default     = "f5-cne-core"
}

variable "instance_namespace" {
  description = "Instance namespace (dssm + f5-cne-controller live here). Gold-standard split: f5-cne-system. Auto-wired from bnk-prereqs.instance_namespace."
  type        = string
  default     = "f5-cne-system"
}

variable "cneinstall_ready" {
  description = "Ordering gate from cneinstall — the heals run after the CNEInstance + IRSA are applied. Auto-wired from cneinstall.host_device_applied (or any cneinstall output) in the blueprint."
  type        = bool
  default     = true
}
