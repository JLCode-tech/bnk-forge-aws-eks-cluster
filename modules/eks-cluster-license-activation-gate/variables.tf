# =============================================================================
# Forge-injected kubeconfig (fallback path)
# =============================================================================
# When the caller does not pass an explicit kubeconfig_file path, this module
# materialises one from local.forge_kubeconfig (injected by Forge at deploy
# time via a generated bnk_forge_providers.tf) or from forge_kubeconfig_content
# for standalone / unit runs. Same seam as cneinstance-ready-gate (P1).

variable "forge_kubeconfig_content" {
  description = "Kubeconfig YAML content. Used only when kubeconfig_file is empty. Auto-injected by Forge."
  type        = string
  sensitive   = true
  default     = ""
}

variable "kubeconfig_file" {
  description = "Path to an existing kubeconfig file. Pass the wrapper module's local_sensitive_file.kubeconfig.filename so both share one materialised kubeconfig. Empty = this module materialises its own from forge_kubeconfig_content."
  type        = string
  default     = ""
}

# =============================================================================
# License CR identity (wired from the cneinstall step)
# =============================================================================

variable "license_namespace" {
  description = "Namespace the License CR is applied into. On the forge EKS module this is var.operator_namespace (default f5-operator) — NOT awsbnkctl's f5-cne-core. The license controller (FLO) runs here."
  type        = string
}

variable "license_name" {
  description = "Name of the License CR to apply and poll."
  type        = string
  default     = "bnk-license"
}

variable "jwt_token" {
  description = "Raw F5 BNK JWT licensing token. Inlined into the License CR's spec.jwt (trimmed). Same secret the FLO module takes. Never echoed to logs."
  type        = string
  sensitive   = true
}

variable "license_crd_name" {
  description = "Fully-qualified License CRD name used by the CRD pre-gate. FLO installs this CRD."
  type        = string
  default     = "licenses.k8s.f5net.com"
}

# =============================================================================
# License CR spec inputs
# =============================================================================

variable "operation_mode" {
  description = "License operationMode. 'connected' = TEEM online activation (the only supported mode here). Disconnected/air-gapped (f5licenseproxy) is out of scope."
  type        = string
  default     = "connected"
}

variable "teem_cert_url" {
  description = "TEEM cert URL for the License CR (spec.teemCertUrl). Defaults from awsbnkctl license-cr.yaml.tmpl; override on a BNK-release bump."
  type        = string
  default     = "https://product.apis.f5.com/ee/v1"
}

variable "teem_entitlement_url" {
  description = "TEEM entitlement URL for the License CR (spec.teemEntitlementUrl)."
  type        = string
  default     = "https://product-s.apis.f5.com/ee/v1"
}

variable "teem_initial_config_url" {
  description = "TEEM initial-config URL for the License CR (spec.teemInitialConfigUrl)."
  type        = string
  default     = "https://product-s.apis.f5.com/ee/v1"
}

# =============================================================================
# Gate tuning
# =============================================================================

variable "activation_timeout_seconds" {
  description = "Max seconds to wait for License .status.state == \"Active\" before failing closed. Mirrors awsbnkctl phase25's ~9.5 min cap (30s initial + 18x30s)."
  type        = number
  default     = 570
}

variable "crd_timeout_seconds" {
  description = "Max seconds to wait for the License CRD to be registered (FLO installs it) before applying the CR."
  type        = number
  default     = 300
}

variable "crd_poll_interval_seconds" {
  description = "Seconds between CRD pre-gate poll iterations."
  type        = number
  default     = 5
}

variable "poll_interval_seconds" {
  description = "Seconds between activation-gate poll iterations."
  type        = number
  default     = 30
}
