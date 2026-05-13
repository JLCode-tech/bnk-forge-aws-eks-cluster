# BNK Prerequisites Module

## Overview

The first module in the BNK stack. Creates required namespaces, distributes FAR image pull secrets, downloads the BNK manifest from repo.f5.com, and parses component versions (FLO version, cert-manager version, etc.).

## What It Does

1. **Creates namespaces**: `f5-operator` (BNK components), `f5-utils` (IPAM), `gateway-ns` (Gateway resources)
2. **Creates FAR secrets**: Image pull secrets in all namespaces for `repo.f5.com` access
3. **Downloads BNK manifest**: From F5 Artifact Registry using the service account key
4. **Parses versions**: Extracts FLO Helm chart version and component versions from manifest
5. **Destroy cleanup**: Strips F5 finalizers and webhooks to prevent stuck resources

## Dependencies

- **EKS Cluster**: Running Kubernetes cluster with valid credentials
- No other BNK modules — this is the entry point

## Usage

```hcl
module "bnk_prerequisites" {
  source = "./k8s/bnk-prerequisites"

  # F5 service account key (project secret)
  cne_pull_secret = var.cne_pull_secret  # base64-encoded JSON

  # BNK manifest version
  bnk_manifest_version = "2.2.0-3.2226.0-0.0.385"

  # Namespace configuration (defaults are standard)
  operator_namespace = "f5-operator"
  utils_namespace    = "f5-utils"
  gateway_namespace  = "gateway-ns"

  # Cluster (auto-wired)
  cluster_name = module.eks.cluster_name
}
```

## Inputs

| Name | Description | Type | Required | Default |
|------|-------------|------|----------|---------|
| cne_pull_secret | Base64-encoded F5 FAR service account key | string (sensitive) | yes | - |
| bnk_manifest_version | BNK manifest version to download | string | no | "2.2.0-3.2226.0-0.0.385" |
| operator_namespace | Namespace for FLO + BNK components | string | no | "f5-operator" |
| utils_namespace | Namespace for utility components | string | no | "f5-utils" |
| gateway_namespace | Namespace for Gateway API resources | string | no | "gateway-ns" |
| cluster_name | Kubernetes cluster name | string | no | "" |

## Outputs

| Name | Description |
|------|-------------|
| operator_namespace | Operator namespace name |
| utils_namespace | Utils namespace name |
| gateway_namespace | Gateway namespace name |
| far_secret_name | FAR image pull secret name (always "far-secret") |
| flo_version | FLO Helm chart version (parsed from manifest) |
| manifest_version | BNK manifest version used |
| component_versions | All component versions from manifest |
| cert_manager_version | F5 cert-manager version (informational) |
| prerequisites_ready | Gate — true when all prerequisites are ready |

## Verification

```bash
# Check namespaces
kubectl get ns | grep -E "f5-operator|f5-utils|gateway-ns"

# Check FAR secrets exist in all namespaces
kubectl get secret far-secret -n f5-operator
kubectl get secret far-secret -n f5-utils
kubectl get secret far-secret -n gateway-ns
```

## References

- [F5 BNK Installation](https://clouddocs.f5.com/bigip-next-for-kubernetes/latest/installing-bnk-dpu-using-f5-lifecycle-operator/installing/bnk-install-flo.html)

## Module Metadata

- **Category**: k8s
- **Workflow Compatibility**: Greenfield, Partial
- **Version**: 2.2.0
- **Last Updated**: 2026-03-04
