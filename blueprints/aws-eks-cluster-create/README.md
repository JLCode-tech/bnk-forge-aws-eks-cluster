# Blueprint: AWS EKS Cluster Create

Provision a new AWS EKS cluster (VPC + 3 AZs + managed node group) and install the BNK 2.2 platform on it.

Uses `terraform-aws-modules/vpc/aws` and `terraform-aws-modules/eks/aws` for the VPC + cluster — production hardening (IMDSv2, EBS encryption, OIDC, control-plane logging) comes from a widely-audited community baseline.

## Prerequisites

- AWS credential template (any of Forge's 3 auth methods). Principal needs VPC + EKS + IAM create privileges.
- Project secret `cne_pull_secret` — base64 F5 FAR registry credentials.
- Project secret `jwt_token` — F5 BNK License JWT.

## Inputs

The deploy form asks for **one thing the user actually types**: `eks_cluster_name`. AWS creds + region auto-fill from the credential template + project.

| Field | Default | Notes |
|---|---|---|
| `worker_instance_type` | `m5.large` | EC2 type for the default node group |
| `worker_count_per_az` | `1` | Nodes per AZ (3 AZs = 3 nodes total) |
| `vip_cidr`, `tmm_replicas`, `deployment_size` | auto / 0 / Small | Same as existing-cluster variant |

## What it builds in AWS

- 1× VPC (`10.0.0.0/16`), IGW, single NAT, 3× private + 3× public subnets across 3 AZs
- 1× EKS cluster + managed node group with `app=f5-tmm` labels (where applicable)
- IRSA OIDC provider (auto-wired)
- The full BNK install chain on top (same as existing-cluster variant)

## Estimated cost

EKS control plane (~$0.10/hr) + 3× `m5.large` + NAT + EBS. AWS usage-based; tear down with `tofu destroy`.

## Variants

- **`aws-eks-existing-cluster`** — install onto an existing cluster instead.
- **`aws-eks-cluster-create-with-hp-nodes`** — adds the dedicated HP TMM node pool.
