# =============================================================================
# Forge-injected kubeconfig
# =============================================================================
# local.forge_kubeconfig is injected at deploy time via a generated
# bnk_forge_providers.tf. Falls back to forge_kubeconfig_content for
# standalone runs outside Forge.

variable "forge_kubeconfig_content" {
  description = "Kubeconfig YAML content. Auto-injected by Forge."
  type        = string
  default     = ""
  sensitive   = true
}

# =============================================================================
# AWS credentials (resolved by Forge from the credential template — works with
# all three Forge AWS auth methods: access_keys, profile, sso)
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
# Cluster identity (auto-wired from cluster-register)
# =============================================================================

variable "eks_cluster_name" {
  description = "EKS cluster name. Used to scope IAM resource names."
  type        = string
}

variable "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL of the EKS cluster. Used for the IRSA trust policy."
  type        = string
}

# =============================================================================
# Namespaces (auto-wired from bnk-prereqs)
# =============================================================================

variable "operator_namespace" {
  description = "Namespace where FLO and CNE controller live. CNEInstance CR is also applied here."
  type        = string
  default     = "f5-operator"
}

variable "utils_namespace" {
  description = "Utils namespace."
  type        = string
  default     = "f5-utils"
}

# =============================================================================
# CR-wired values (auto-wired from upstream modules)
# =============================================================================

variable "manifest_version" {
  description = "BNK manifest version. Auto-wired from bnk-prereqs.manifest_version."
  type        = string
}

variable "far_secret_name" {
  description = "FAR image pull secret name. Auto-wired from bnk-prereqs."
  type        = string
  default     = "far-secret"
}

variable "cluster_issuer_name" {
  description = "ClusterIssuer for CNEInstance certificates. Auto-wired from cert-issuer."
  type        = string
  default     = "bnk-ca-cluster-issuer"
}

variable "flo_ready" {
  description = "Gate from FLO module — must be true (FLO running + CRDs registered) before applying the CNEInstance CR."
  type        = bool
  default     = true
}

variable "crds_installed" {
  description = "Gate from FLO module — must be true (CRDs registered) before applying the CNEInstance CR."
  type        = bool
  default     = true
}

# =============================================================================
# User-facing CNEInstance config (exposed as blueprint inputs)
# =============================================================================

variable "instance_name" {
  description = "Name of the CNEInstance CR."
  type        = string
  default     = "default-f5-cne-controller"
}

variable "deployment_size" {
  description = "CNEInstance deploymentSize. One of: Small, Medium, Large."
  type        = string
  default     = "Small"
}

variable "tmm_replicas" {
  description = "Number of TMM replicas to deploy. Typically one per AZ for multi-AZ setups."
  type        = number
  default     = 3
}

variable "watch_namespaces" {
  description = "Which namespaces the CNE controller watches for Gateway/HTTPRoute CRs. Use [\"All\"] to watch everything."
  type        = list(string)
  default     = ["All"]
}

variable "network_attachments" {
  description = "NetworkAttachmentDefinition names the TMM data plane uses. Defaults to the ipvlan NAD applied by the network-setup module."
  type        = list(string)
  default     = ["ens7-ipvlan-l2"]
}

variable "storage_class_name" {
  description = "Kubernetes StorageClass for CNEInstance persistent state. AWS gp3 is the default per the EKS BNK install guide."
  type        = string
  default     = "gp3"
}

# =============================================================================
# Cloud network mapping (REQUIRED on AWS — the CNE controller reads this
# ConfigMap to know how AZs map to subnets for ENI placement)
# =============================================================================

variable "cloud_az_subnet_mappings" {
  description = <<-EOT
    AWS availability-zone → subnet mapping consumed by the CNE controller via
    the cloud-network-mapping ConfigMap. Required for AWS multi-AZ TMM
    placement. Each entry names an AZ and lists its subnet CIDRs + IDs.

    Example:
      [
        { name = "us-east-1a", subnets = [{ cidr = "192.168.1.0/24", subnet_id = "subnet-aaa" }] },
        { name = "us-east-1b", subnets = [{ cidr = "192.168.2.0/24", subnet_id = "subnet-bbb" }] }
      ]

    Empty list = skip ConfigMap creation; the CNE controller will reference a
    missing ConfigMap and fail to compute AZ placement. Don't leave empty for
    production.
  EOT
  type = list(object({
    name = string
    subnets = list(object({
      cidr      = string
      subnet_id = string
    }))
  }))
  default = []
}

# =============================================================================
# F5BnkGateway chassis CR (AWS-specific — without this CR the CNE controller
# silently ignores all Gateway/HTTPRoute CRs even when CNEInstance is
# Programmed=True. Documented in bnk-forge-modules PR #58.)
# =============================================================================

variable "bnk_gateway_chassis" {
  description = <<-EOT
    F5BnkGateway chassis CR config. Required on AWS/EKS for Gateway-API
    translation. Without this CR, the CNE controller logs 'Watched application
    namespaces: []' and ignores all Gateway+HTTPRoute CRs.

    Use explicit start_address + end_address per listener network. The CRD's
    ipv4BaseCidr alternative is rejected by the controller runtime.

    Empty default_listener_networks list = skip chassis CR creation.
  EOT
  type = object({
    name = optional(string, "bnk-gateway-chassis")
    default_listener_networks = list(object({
      name          = string
      start_address = string
      end_address   = string
    }))
  })
  default = {
    default_listener_networks = []
  }
}

# =============================================================================
# IRSA tuning (rarely overridden)
# =============================================================================

variable "cne_controller_sa_name" {
  description = "CNE controller ServiceAccount name pattern. Used in the IRSA trust policy."
  type        = string
  default     = "f5-cne-controller-default-f5-cne-controller-serviceaccount"
}

variable "cne_controller_deployment_name" {
  description = "CNE controller Deployment name. Used to rollout-restart after annotating the SA with the IRSA role."
  type        = string
  default     = "f5-cne-controller"
}

variable "wait_for_sa_timeout_seconds" {
  description = "Max seconds to wait for FLO to create the CNE controller SA after the CNEInstance CR is applied."
  type        = number
  default     = 600
}

variable "extra_irsa_managed_policy_arns" {
  description = "Additional managed IAM policy ARNs to attach to the CNE controller's IRSA role."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to AWS IAM resources created by this module."
  type        = map(string)
  default     = {}
}
