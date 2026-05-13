# Blueprint: AWS EKS Existing Cluster

Adopt an existing AWS EKS cluster into BNK Forge and lay down the shared BNK k8s prerequisites.

## What this blueprint does today

| Step | Module | Status |
|---|---|---|
| 1 | `eks-cluster-register` — discover and adopt an existing EKS cluster | Implemented |
| 2 | `eks-cluster-install-bnk-prereqs` — namespaces, FAR pull secrets, manifest | Implemented (vendored from `bnk-forge-catalog-shared`) |
| 3 | `eks-cluster-install-cert-manager` — install Jetstack cert-manager | Implemented (vendored) |
| 4 | `eks-cluster-install-cert-issuer` — BNK CA + ClusterIssuer | Implemented (vendored) |
| 5 | `eks-cluster-install-flo` — install F5 Lifecycle Operator with AWS IRSA | Not yet implemented |
| 6 | `eks-cluster-cneinstall` — deploy a `CNEInstance` CR (with AWS chassis) | Not yet implemented |
| 7 | `eks-cluster-license` — apply the BNK License CR | Not yet implemented |

Current revision: `version: 0.2.0`, `maturity: preview`. Subsequent PRs add FLO, CNEInstance, and License — at which point this blueprint will deploy BNK end-to-end onto an existing EKS cluster.

## Inputs (current revision)

| Name | Source | Required | Description |
|---|---|---|---|
| `aws_access_key_id` | AWS credential template | Yes | AWS access key ID. |
| `aws_secret_access_key` | AWS credential template | Yes | AWS secret access key. |
| `aws_region` | AWS credential template | Yes | Region where the cluster resides. |
| `eks_cluster_name` | User | Yes | Name of the existing EKS cluster. |
| `cne_pull_secret` | Project secret | Yes | Base64-encoded F5 FAR registry credentials. |
| `aws_session_token` | AWS credential template | No | STS session token for assumed-role credentials. |
| `operator_namespace` | User | No | Namespace for FLO and BNK components. Default `f5-operator`. |
| `utils_namespace` | User | No | Namespace for utility components. Default `f5-utils`. |
| `gateway_namespace` | User | No | Namespace for Gateway API resources. Default `bnk-gw`. |
| `bnk_manifest_version` | User | No | BNK manifest version to download. Default `2.2.1-3.2226.0-0.0.511`. |

## Module chain (depends_on graph)

```
cluster-register
    └─→ bnk-prereqs
            └─→ cert-manager
                    └─→ cert-issuer
```

## What you get

After apply:

- BNK Forge auto-registers the cluster in the Kubernetes inventory using `cluster_name`, `cluster_id` (ARN), `cluster_endpoint`, `region`, and the emitted `kubeconfig`.
- BNK namespaces (`f5-operator`, `f5-utils`, `bnk-gw`) and FAR image pull secrets exist on the cluster.
- The BNK component manifest has been downloaded and parsed — component versions are available for downstream FLO install.
- Jetstack cert-manager is installed and healthy.
- The BNK CA + CA-backed ClusterIssuer is ready for use by FLO (when implemented) and OTEL certificate flows.

## What's still required to deploy BNK end-to-end

Until FLO, CNEInstance, and License modules ship in this repo, run those steps manually after this blueprint applies. Or wait for the next PR.
