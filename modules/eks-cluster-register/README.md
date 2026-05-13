# eks-cluster-register

Reference an existing AWS EKS cluster and emit the outputs BNK Forge needs to register the cluster in its Kubernetes inventory.

## When to use this module

Use this when you want to deploy BNK onto an EKS cluster that already exists — provisioned outside Forge, by another team, or via a separate IaC pipeline.

If you want Forge to provision a new cluster end-to-end, use `eks-cluster-create` instead.

## What it does

- Looks up the existing EKS cluster via `data.aws_eks_cluster`.
- Fetches a short-lived STS authentication token via `data.aws_eks_cluster_auth`.
- Synthesizes a kubeconfig and returns it base64-encoded as an output.
- Emits BNK Forge's canonical cluster-registration shape: `cluster_id`, `cluster_name`, `cluster_endpoint`, `region`, `kubeconfig`.

The kubeconfig embeds a literal token (no `exec` to `aws eks get-token`), so any consumer with the kubeconfig bytes can use it directly during the validity window. Forge ingests it on first scan, well before the token expires.

## Inputs

| Name | Source | Required | Description |
|---|---|---|---|
| `aws_access_key_id` | AWS credential template | Yes | IAM access key ID. |
| `aws_secret_access_key` | AWS credential template | Yes | IAM secret access key. |
| `aws_region` | AWS credential template | Yes | Region where the cluster resides. |
| `eks_cluster_name` | User | Yes | The EKS cluster name to adopt. |
| `aws_session_token` | AWS credential template | No | STS session token, only for assumed-role credentials. |

## Outputs

| Output | Used by |
|---|---|
| `cluster_id` | BNK Forge registration |
| `cluster_name` | BNK Forge registration |
| `cluster_endpoint` | BNK Forge registration |
| `region` | BNK Forge registration |
| `kubeconfig` | BNK Forge registration (base64-encoded) |
| `cluster_certificate_authority_data` | Downstream modules building their own kubeconfig |
| `cluster_oidc_issuer_url` | IRSA configuration in FLO/CNEInstance install modules |
| `eks_cluster_arn`, `eks_cluster_version` | Reference fields |

## Required IAM permissions

The credentials must allow at minimum:

- `eks:DescribeCluster` on the target cluster
- `sts:GetCallerIdentity` (used by the EKS auth flow)

For the resulting kubeconfig to actually authenticate against the cluster, the principal must also be mapped into the cluster's `aws-auth` ConfigMap (for `system:masters` or another bound role).
