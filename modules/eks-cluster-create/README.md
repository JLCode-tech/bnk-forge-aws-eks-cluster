# eks-cluster-create

Provision a new AWS EKS cluster — VPC, subnets, NAT, managed node group, and an IRSA OIDC provider — ready for BNK to install on top.

## When to use this module

Use this when you want Forge to stand up an EKS cluster end-to-end. The `aws-eks-cluster-create` blueprint chains this module with the BNK install modules (`bnk-prereqs` → `cert-manager` → `cert-issuer` → `flo` → `cneinstall`) so a single deploy produces a working BNK environment.

If you already have an EKS cluster and just want to install BNK on it, use `eks-cluster-register` + the `aws-eks-cluster-existing` blueprint instead.

## What it builds

| Layer | Resource | Source |
|---|---|---|
| Network | VPC, IGW, single NAT, public + private subnets across 3 AZs | `terraform-aws-modules/vpc/aws ~> 6.0` |
| Cluster | EKS control plane + managed node group + cluster/node IAM roles + IRSA OIDC provider | `terraform-aws-modules/eks/aws ~> 21.0` |
| BNK glue | `f5-bnk-role=tmm-external` tag on private subnets; kubeconfig synthesis; outputs matching `eks-cluster-register` | This module |

The community modules ship with production-hardened defaults (IMDSv2-required launch template, EBS-encrypted root volumes, control-plane logging, private + public endpoint, latest AL2023 AMI). We deliberately do not configure Karpenter, Fargate, KMS secrets encryption, or multiple node groups — keep it minimal; BNK adds its own complexity on top.

## Why community modules

`terraform-aws-modules/eks/aws` and `terraform-aws-modules/vpc/aws` are the de-facto Terraform community standard for AWS — widely audited, kept current with EKS feature releases, and recognisable to any AWS engineer reading this catalog. Re-implementing the same VPC + EKS plumbing in-repo would be hundreds of lines of code we'd have to keep in step with AWS-side changes.

We accept the external-module dependency in exchange for that maintenance surface. Versions are pinned with `~>` so minor upgrades flow through but major bumps are explicit.

## Inputs

| Name | Source | Required | Default | Description |
|---|---|---|---|---|
| `aws_access_key_id` | AWS credential template | Yes | — | IAM access key ID. |
| `aws_secret_access_key` | AWS credential template | Yes | — | IAM secret access key. |
| `aws_region` | User | Yes | — | Region to deploy in. |
| `eks_cluster_name` | User | Yes | — | Name for the new cluster (also used as a prefix for VPC, subnets, IAM roles). |
| `aws_session_token` | AWS credential template | No | `""` | STS session token; only populated for assumed-role / SSO. |
| `eks_cluster_version` | User | No | `""` (latest) | Kubernetes minor version, e.g. `1.30`. |
| `vpc_cidr` | User | No | `10.0.0.0/16` | CIDR for the new VPC. |
| `worker_instance_type` | User | No | `m5.large` | Node group EC2 type. |
| `worker_count_per_az` | User | No | `1` | Desired nodes per AZ; total = this × AZ count. |
| `worker_disk_size_gb` | User | No | `50` | Worker root volume size. |
| `tag_private_subnets_for_tmm` | User | No | `true` | Tag private subnets with `f5-bnk-role=tmm-external` so `cneinstall` auto-builds the BNKGateway CR's `defaultListenerNetworks`. |

Advanced knobs (`availability_zones`, `private_subnet_newbits`, `public_subnet_newbits`, `tags`) are exposed as Terraform variables for direct callers but are not surfaced in the Forge UI — their defaults work for every deployment we've validated.

## Outputs

Outputs match `eks-cluster-register` so the downstream install chain is identical regardless of provisioning path.

| Output | Used by |
|---|---|
| `cluster_id` | BNK Forge registration |
| `cluster_name`, `cluster_endpoint`, `region`, `kubeconfig` | BNK Forge registration |
| `cluster_oidc_issuer_url`, `cluster_certificate_authority_data` | Downstream FLO / CNEInstance |
| `vpc_id`, `vpc_cidr`, `subnet_ids`, `private_subnet_ids`, `public_subnet_ids` | Downstream `cneinstall` |
| `cloud_az_subnet_mappings` | `cneinstall` (cloud-network-mapping ConfigMap) |
| `tmm_external_subnets_by_az` | `cneinstall` (BNKGateway `defaultListenerNetworks`) |
| `availability_zone_count`, `worker_node_count` | `cneinstall` (smart `tmm_replicas` default) |
| `oidc_provider_arn` | Anything wanting the IRSA OIDC ARN directly |

## Required IAM permissions

The credentials must allow:

- VPC: `ec2:CreateVpc`, `ec2:CreateSubnet`, `ec2:CreateNatGateway`, `ec2:CreateInternetGateway`, `ec2:AllocateAddress`, `ec2:CreateRouteTable`, `ec2:CreateRoute`, `ec2:AssociateRouteTable`, plus the corresponding `Describe*` and `Tag*` actions.
- EKS: `eks:CreateCluster`, `eks:CreateNodegroup`, `eks:CreateAddon`, plus the corresponding `Describe*` and `Tag*` actions.
- IAM: `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:CreateOpenIDConnectProvider`, `iam:CreatePolicy` (some attached managed; module also creates inline scoped policies).
- STS: `sts:GetCallerIdentity`.

In practice, an Administrator-equivalent identity is the easiest way to validate; tighten the scope from the Terraform plan output in production.

## Maturity

`beta` — moves to `1.0.0` once both blueprints (`aws-eks-cluster-existing` and `aws-eks-cluster-create`) have been end-to-end validated together.
