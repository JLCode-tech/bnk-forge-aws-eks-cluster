# Blueprint: AWS EKS Cluster Create

Provision a brand-new AWS EKS cluster end-to-end and lay down the BNK control plane on top. Twin of `aws-eks-existing-cluster` — same install chain, different starting point.

## What this blueprint does

| Step | Module | Status |
|---|---|---|
| 1 | `eks-cluster-create` — provision VPC + EKS cluster + node group + IRSA OIDC | Implemented (beta) |
| 2 | `eks-cluster-install-bnk-prereqs` — namespaces, FAR pull secrets, manifest | Implemented (vendored) |
| 3 | `eks-cluster-install-cert-manager` — install Jetstack cert-manager | Implemented (vendored) |
| 4 | `eks-cluster-install-cert-issuer` — BNK CA + ClusterIssuer | Implemented (vendored) |
| 5 | `eks-cluster-install-flo` — install F5 Lifecycle Operator via Helm (AWS-tuned values) | Implemented |
| 6 | `eks-cluster-cneinstall` — CNEInstance CR + cloud-network-mapping + BNKGateway CR + AWS IRSA | Implemented |
| 7 | `eks-cluster-license` — apply the BNK License CR | Not yet implemented |

Current revision: `version: 0.1.0`, `maturity: beta`. Stays beta until both blueprints (`existing` and `create`) have been validated end-to-end against a live AWS account — then both move to `1.0.0`.

## Why two blueprints

Same install chain, different first step:

- **`aws-eks-existing-cluster`** — you already have an EKS cluster. Step 1 adopts it.
- **`aws-eks-cluster-create`** — you want Forge to stand up the cluster from scratch. Step 1 provisions VPC + EKS via `terraform-aws-modules/vpc/aws` and `terraform-aws-modules/eks/aws`.

Outputs of step 1 are identical in shape across both blueprints (`cluster_id`, `cluster_oidc_issuer_url`, `cloud_az_subnet_mappings`, `tmm_external_subnets_by_az`, etc.) so steps 2-6 are unchanged.

## Inputs

| Name | Source | Required | Description |
|---|---|---|---|
| `aws_access_key_id` | AWS credential template | Yes | AWS access key ID. |
| `aws_secret_access_key` | AWS credential template | Yes | AWS secret access key. |
| `aws_region` | AWS credential template / project | Yes | Region to provision in. |
| `eks_cluster_name` | User | Yes | Name for the new EKS cluster (also a prefix for VPC, subnets, IAM roles). |
| `cne_pull_secret` | Project secret | Yes | Base64-encoded F5 FAR registry credentials. |
| `jwt_token` | Project secret | Yes | F5 BNK License JWT. |
| `aws_session_token` | AWS credential template | No | STS session token for assumed-role / SSO credentials. |
| `eks_cluster_version` | User | No | Kubernetes minor version (e.g. `1.30`). Empty = latest. |
| `vpc_cidr` | User | No | New VPC CIDR. Default `10.0.0.0/16`. |
| `worker_instance_type` | User | No | Node group EC2 type. Default `m5.large`. |
| `worker_count_per_az` | User | No | Nodes per AZ. Default `1`. Total nodes = this × 3 AZs. |
| `worker_disk_size_gb` | User | No | Worker root volume. Default `50`. |
| `tag_private_subnets_for_tmm` | User | No | Tag private subnets with `f5-bnk-role=tmm-external` so cneinstall auto-builds the BNKGateway CR. Default `true`. |
| `operator_namespace` | User | No | FLO + BNK ns. Default `f5-operator`. |
| `utils_namespace` | User | No | Utility ns. Default `f5-utils`. |
| `gateway_namespace` | User | No | Gateway API ns. Default `bnk-gw`. |
| `bnk_manifest_version` | User | No | BNK manifest version. Default `2.2.1-3.2226.0-0.0.511`. |
| `license_mode` | User | No | FLO license: `connected` (default) or `f5licenseproxy`. |
| `container_platform` | User | No | FLO containerPlatform. Default `AWS`. |
| `deployment_size` | User | No | CNEInstance size: Small/Medium/Large/Max. Default `Small`. |
| `tmm_replicas` | User | No | TMM replicas. Default `0` = auto: `min(AZ count, worker node count)`. |
| `watch_namespaces` | User | No | CNE controller watches. Default `["All"]`. |
| `network_attachments` | User | No | NAD names on TMM. Default `["ens7-ipvlan-l2"]`. |
| `vip_cidr` | User | No | Explicit VIP CIDR. Empty = derive from tag-discovered subnets. |

> **Auto-wired module-to-module outputs** (you don't see these in the form): `cluster_oidc_issuer_url`, `cloud_az_subnet_mappings`, `tmm_external_subnets_by_az`, `availability_zone_count`, `worker_node_count`, `vpc_cidr` all flow from `cluster-create` into `cneinstall`. Output names match `eks-cluster-register` exactly so the wiring is identical between the two blueprints.

## What this builds in AWS

A fresh VPC + EKS cluster from `terraform-aws-modules`:

| Layer | Resource |
|---|---|
| Network | 1× VPC (`vpc_cidr`), IGW, single shared NAT, 3× private subnets, 3× public subnets across 3 AZs |
| Subnet tags | `kubernetes.io/role/internal-elb`=`1` on private; `kubernetes.io/role/elb`=`1` on public; `f5-bnk-role`=`tmm-external` on private (when `tag_private_subnets_for_tmm`=true) |
| Cluster | 1× EKS cluster (`eks_cluster_name`), public + private endpoints, control-plane logs, latest AL2023 nodes, IMDSv2 required, EBS-encrypted root |
| Node group | 1× managed node group `default` (instance type/size/count from inputs) |
| IAM | Cluster role + node role + IRSA OIDC provider (created by the EKS community module) |

## Production hardening

We deliberately leverage `terraform-aws-modules/eks/aws ~> 21.0` so we inherit the AWS Terraform community's production defaults:

- IMDSv2 required on all nodes
- EBS root volumes encrypted with the default AWS-managed key
- Cluster control-plane logging enabled
- Private + public API endpoint (the catalog assumes Forge can reach the public endpoint; tighten this if your security model needs private-only)
- Latest stable AL2023 AMI for node group

What we **don't** configure (intentionally — keep it minimal, BNK adds its own complexity on top): Karpenter, Fargate profiles, multiple node groups, customer-managed KMS secrets encryption, extra cluster access entries. Add them in a follow-up module if your account standards require it.

## Required IAM permissions

The credentials need VPC + EKS + IAM create-class privileges. The simplest validation path is an Administrator-equivalent identity; tighten the scope from the Terraform plan output once the blueprint has run successfully. See the [`eks-cluster-create` module README](../../modules/eks-cluster-create/README.md) for the per-resource action list.

## Cluster admin prerequisite (manual)

Even with a fresh cluster, FLO still needs nodes explicitly labelled for TMM:

```bash
kubectl label node <node-name> app=f5-tmm
```

For the default `worker_count_per_az: 1` × 3 AZs = 3 nodes, label all three. The `tmm_replicas: 0` auto-default then resolves to 3.

## Module chain (depends_on graph)

```
cluster-create
    └─→ bnk-prereqs
            └─→ cert-manager
                    └─→ cert-issuer
                            └─→ flo
                                    └─→ cneinstall
```

## Estimated time + cost

- **Time:** 25-40 minutes end-to-end. EKS control-plane provisioning takes ~10-15 min; node group ~5 min; BNK install chain ~10-15 min.
- **Cost:** AWS usage-based. EKS control plane (~$0.10/hr) + 3× `m5.large` nodes + NAT gateway ($0.045/hr + data) + EBS volumes. Tear down with `tofu destroy` when finished testing.
