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

variable "vpc_id" {
  description = "EKS cluster VPC ID. cneinstall rediscovers f5-bnk-role=tmm-external subnets at apply time scoped to this VPC, so newly-created HP-nodes TMM subnets land in the BNKGateway CR even though they didn't exist when the upstream provisioning module ran its own discovery."
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
# Licensing (wired to the License activation gate, chained after readiness)
# =============================================================================

variable "jwt_token" {
  description = "F5 BNK JWT licensing token. Bind to the same project secret the FLO module uses. Passed to the license-activation-gate, which applies the License CR (spec.jwt) and gates on .status.state == Active. Never logged."
  type        = string
  sensitive   = true
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
  description = <<-EOT
    Number of TMM replicas to deploy.

    Default 0 = auto-derive from cluster topology: min(availability_zone_count,
    worker_node_count). The 1-TMM-per-AZ pattern from the F5 install guide is
    the natural default; worker node count caps that (a TMM pod can't schedule
    without an available node labeled app=f5-tmm).

    Set to a positive number to override. Cluster admin must still have
    labeled enough nodes with app=f5-tmm for the requested count to schedule.
  EOT
  type        = number
  default     = 0
}

# Auto-wired from cluster-register — used to compute the smart tmm_replicas
# default when the user leaves tmm_replicas = 0.
variable "availability_zone_count" {
  description = "Number of distinct AZs the cluster spans. Auto-wired from cluster-register."
  type        = number
  default     = 3
}

variable "worker_node_count" {
  description = "Total worker node count in the cluster (sum across node groups). Auto-wired from cluster-register. Caps the smart tmm_replicas default."
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
# BNKGateway CR (kind: F5BnkGateway) — AWS/EKS Gateway-API IPAM CR.
# Without this CR the CNE controller silently ignores all Gateway/HTTPRoute
# CRs even when CNEInstance is Programmed=True. Discovery trail in
# bnk-forge-modules PR #58. (F5 docs call this BNKGateway / F5BnkGateway;
# the historical "chassis" terminology has been removed from this module.)
# =============================================================================

variable "vip_cidr" {
  description = <<-EOT
    CIDR block for BNK Gateway VIP allocation — explicit override.

    Resolution order for the BNKGateway CR's defaultListenerNetworks:
      1. If `vip_cidr` is non-empty → single listener network derived from this CIDR
         (start_address = cidrhost(vip_cidr, 1), end_address = cidrhost(vip_cidr, -2)).
         Wins over auto-discovery; use when VIPs live somewhere other than the
         TMM external AZ subnets (e.g. a TGW-routed external CIDR).
      2. Else if cluster-register's `tmm_external_subnets_by_az` is non-empty
         (customer tagged AWS subnets with `f5-bnk-role=tmm-external`) → multi-AZ
         listener networks auto-derived, one per AZ subnet.
      3. Else → the BNKGateway CR is skipped (preserves on-prem default; the CNE
         controller will then silently ignore Gateway/HTTPRoute CRs).

    Pick a CIDR carved from the cluster VPC or from a TMM external AZ subnet
    (clients in that subnet reach VIPs directly without BGP). For a VPC of
    192.168.0.0/16, a common explicit pattern is 192.168.250.0/24.
  EOT
  type        = string
  default     = ""
}

variable "tmm_external_subnets_by_az" {
  description = <<-EOT
    AZ → TMM external subnets list discovered by cluster-register via the
    AWS subnet tag `f5-bnk-role=tmm-external`. Same shape as
    cloud_az_subnet_mappings: [{name=<az>, subnets=[{cidr, subnet_id}, ...]}, ...].

    When `vip_cidr` is empty and this list is non-empty, cneinstall builds the
    BNKGateway CR's defaultListenerNetworks with one entry per AZ subnet —
    customers who tag their data-plane subnets in AWS don't need to supply
    vip_cidr.

    Note: the listener network covers the full subnet CIDR by default
    (cidrhost +1 to cidrhost -2). If your TMM selfip IPs are inside that
    range (per the F5SPKVlan CR you'll apply later), set vip_cidr explicitly
    to a non-overlapping CIDR instead.
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

variable "bnk_gateway_name" {
  description = "Name of the BNKGateway CR (kind: F5BnkGateway)."
  type        = string
  default     = "bnk-gateway"
}

variable "vip_network_name" {
  description = "Logical name for the VIP listener network in the BNKGateway CR's defaultListenerNetworks entry."
  type        = string
  default     = "default"
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
