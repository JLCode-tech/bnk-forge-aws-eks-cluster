# Blueprint: AWS EKS Existing Cluster

Adopt an existing AWS EKS cluster into BNK Forge.

## What this blueprint does today

| Step | Module | Status |
|---|---|---|
| 1 | `eks-cluster-register` — discover and adopt an existing EKS cluster | Implemented |
| 2 | `eks-cluster-install-cert-manager` — install Jetstack cert-manager | Not yet implemented |
| 3 | `eks-cluster-install-bnk-prereqs` — namespaces, FAR pull secrets, manifest | Not yet implemented |
| 4 | `eks-cluster-install-flo` — install F5 Lifecycle Operator | Not yet implemented |
| 5 | `eks-cluster-cneinstall` — deploy a `CNEInstance` CR (with AWS chassis) | Not yet implemented |
| 6 | `eks-cluster-license` — apply the BNK License CR | Not yet implemented |

This is the initial revision (`version: 0.1.0`, `maturity: preview`). It deploys step 1 only. Subsequent PRs will add the remaining modules and update the blueprint to chain them together.

## Inputs (current revision)

| Name | Source | Required | Description |
|---|---|---|---|
| `aws_access_key_id` | AWS credential template | Yes | AWS access key ID. |
| `aws_secret_access_key` | AWS credential template | Yes | AWS secret access key. |
| `aws_region` | AWS credential template | Yes | Region where the cluster resides. |
| `eks_cluster_name` | User | Yes | Name of the existing EKS cluster. |
| `aws_session_token` | AWS credential template | No | STS session token for assumed-role credentials. |

## What you get

After apply:

- BNK Forge auto-registers the cluster in the Kubernetes inventory using `cluster_name`, `cluster_id` (ARN), `cluster_endpoint`, `region`, and the emitted `kubeconfig`.
- The cluster appears on the BNK Forge Kubernetes page without any manual scan step.

## What's still required to deploy BNK end-to-end

Use the cluster-register outputs as inputs to subsequent install steps. Until the rest of the modules in this repo ship, you can:

- Run the install steps from the canonical `bnk-forge-modules` repo manually as separate modules
- Or wait for the next PR in this repo that adds `eks-cluster-install-cert-manager` and beyond
