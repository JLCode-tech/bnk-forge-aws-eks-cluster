# eks-cluster-hp-nodes

Add a dedicated high-performance EKS managed node group with the **3-interface TMM model**: CNI + external + internal. Used by the `aws-eks-existing-cluster-with-hp-nodes` and `aws-eks-cluster-create-with-hp-nodes` blueprints.

## TMM interface model

Each TMM pod on an HP node gets three interfaces:

| Interface | Where it lives | Purpose | NAD |
|---|---|---|---|
| `eth0` (CNI) | Pod network (VPC CNI on `ens5`, the node's primary ENI) | Cluster control-plane traffic, kubelet liveness, service discovery | — (managed by VPC CNI) |
| `net1` | Secondary ENI on TMM-external subnet (`ens7` by default) | **Client-facing data plane** — incoming traffic to BNK VIPs | `ens7-ipvlan-l2` |
| `net2` | Secondary ENI on TMM-internal subnet (`ens8` by default) | **Backend-facing data plane** — outgoing traffic to origin pods/services | `ens8-ipvlan-l2` |

The bootstrap user-data attaches both secondary ENIs at first boot, tagging them `node.k8s.amazonaws.com/no_manage=true` so AWS VPC CNI ignores them.

> **NAD prerequisite:** `ens7-ipvlan-l2` and `ens8-ipvlan-l2` NetworkAttachmentDefinitions must exist on the cluster. They're created manually per the F5 install guide today; a NAD-provisioning module will land in a future PR.

## What it builds

| Resource | Purpose |
|---|---|
| `aws_subnet.tmm_external[*]` (per AZ) | Tagged `f5-bnk-role=tmm-external` — cneinstall rediscovers these at apply time to build BNKGateway CR listener networks |
| `aws_subnet.tmm_internal[*]` (per AZ) | Tagged `f5-bnk-role=tmm-internal` — for future NAD-provisioning module |
| `aws_iam_role.hp_node` + worker/CNI/registry policies | Standard EKS node role |
| `aws_iam_role_policy.hp_node_eni` (inline) | Scoped ENI-management permissions (`CreateNetworkInterface`, `AttachNetworkInterface`, `ModifyNetworkInterfaceAttribute`, `AssignPrivateIpAddresses`, `CreateTags`) |
| `aws_launch_template.hp` | IMDSv2-required, EBS-encrypted, MIME-multipart user-data that bootstraps both secondary ENIs |
| `aws_eks_node_group.hp` | Dedicated managed NG. Default `m5n.large` (supports 3 ENIs total: primary + 2 secondary), `app=f5-tmm` label, optional taints |

## Bootstrap flow

`manifests/launch-template-userdata.sh.tftpl` runs on first boot (before EKS's own bootstrap):

1. IMDSv2 → instance ID + AZ + region
2. Pick AZ-matching external + internal TMM subnets from Terraform-rendered maps
3. **`aws ec2 create-network-interface`** in TMM-external subnet, tagged `no_manage=true` + `f5-bnk:tmm-role=external`
4. **`aws ec2 attach-network-interface --device-index 2`** → `ens7` on AL2023
5. **`modify-network-interface-attribute`** to set `DeleteOnTermination=true`
6. Same sequence for the internal ENI: `device-index 3` → `ens8`, tagged `f5-bnk:tmm-role=internal`
7. Poll `ip link` until the kernel registers BOTH new interfaces

The MIME-multipart format wraps this so EKS's own bootstrap (kubelet bring-up, cluster join) still runs after.

## Instance type constraint

The instance must support at least **3 total ENIs** (1 primary + 2 secondary):

| Type | Total ENIs | Notes |
|---|---|---|
| `m5n.large` (default) | 3 | Minimum that works. SR-IOV + 100Gbps ENA. |
| `m5n.xlarge`, `c5n.xlarge` | 4 | Room to grow. |
| `m5n.2xlarge`, `c5n.2xlarge` | 4 | Higher CPU/memory. |
| `c5n.large` | 3 | Compute-optimised alternative. |
| `t3.medium` | 3 | NOT recommended — burstable CPU is wrong for TMM data-plane. |

Reference: AWS [ENI per instance type table](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-eni.html#AvailableIpPerENI).

## Inputs

| Name | Source | Required | Default | Description |
|---|---|---|---|---|
| `aws_*` creds | AWS credential template | Yes | — | Any of Forge's three auth methods. |
| `aws_region` | User / project | Yes | — | Region. |
| `eks_cluster_name` | Upstream module | Yes | — | Cluster to attach the HP NG to. |
| `vpc_id` | Upstream module | Yes | — | Cluster VPC. |
| `vpc_cidr` | Upstream module | Yes | — | For auto-carving TMM subnets. |
| `availability_zones` | Upstream module | Yes | — | AZs to spread across. |
| `node_subnet_ids` | Upstream module | Yes | — | Where HP nodes place their **primary** ENI. |
| `tmm_external_subnet_cidrs` | User | No | `[]` → auto-carve | Explicit override per-AZ. |
| `tmm_internal_subnet_cidrs` | User | No | `[]` → auto-carve | Explicit override per-AZ. |
| `tmm_external_subnet_index_offset` | User | No | `200` | `cidrsubnet` offset for external auto-carve. |
| `tmm_internal_subnet_index_offset` | User | No | `210` | `cidrsubnet` offset for internal auto-carve. |
| `instance_type` | User | No | `m5n.large` | Must support ≥ 3 ENIs. |
| `node_count_per_az` | User | No | `1` | Set `0` to skip the NG (subnets still created). |
| `external_eni_device_index` | User | No | `2` | `ens7` on AL2023 — matches `ens7-ipvlan-l2` NAD. |
| `internal_eni_device_index` | User | No | `3` | `ens8` on AL2023 — matches `ens8-ipvlan-l2` NAD. |
| `additional_ips_per_eni` | User | No | `0` | Extra IPs on each secondary ENI. `0` = let cneinstall IPAM manage. |
| `node_label_app` | User | No | `f5-tmm` | `app=<value>` on HP nodes. |
| `node_taints` | User | No | `[]` | Optional dedication. |
| `tag_subnets_for_tmm` | User | No | `true` | Apply `f5-bnk-role=tmm-external` / `tmm-internal` tags. |

## Outputs

| Output | Used by |
|---|---|
| `tmm_external_subnet_ids`, `_by_az`, `_cidrs`, `tmm_external_subnets_by_az` | Diagnostics; cneinstall rediscovers via tag |
| `tmm_internal_subnet_ids`, `_by_az`, `_cidrs`, `tmm_internal_subnets_by_az` | Diagnostics; future NAD-provisioning module |
| `hp_node_group_arn`, `_name`, `hp_node_count`, `hp_node_role_arn`, `launch_template_id` | Diagnostics; downstream IRSA |

## Cost considerations

This module adds material AWS cost on top of the base cluster:

- 3× HP nodes (default `m5n.large` ≈ $0.14/hr each ≈ $300/mo)
- 6× secondary ENIs (free, but each consumes a private IP from a TMM subnet)
- 6× TMM subnets (no direct cost; reserve VPC IP space)

For pre-production validation, set `node_count_per_az = 0` to validate the subnet + IAM + LT plumbing without running real nodes.

## Known limitations

- **Destroy-time orphan risk.** Secondary ENIs are marked `DeleteOnTermination=true`, so they go away when the EC2 instance terminates. If something has detached an ENI before destroy, the ENI may leak. After `tofu destroy`, sweep:
  ```bash
  aws ec2 describe-network-interfaces \
    --filters "Name=tag:bnk-forge:cluster,Values=<cluster>" \
              "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output text \
    | xargs -r -n1 aws ec2 delete-network-interface --network-interface-id
  ```
- **First-boot race.** If the AWS API is slow, the kubelet may start before the second ENI is registered. The user-data polls `ip link` for both interfaces for up to 30s.
- **AMI release version.** Default = latest stable AL2023 for the cluster's K8s minor. Pin via `eks_ami_release_version` for byte-for-byte reproducibility.
- **NAD prerequisite.** `ens7-ipvlan-l2` and `ens8-ipvlan-l2` must exist on the cluster before TMM pods can start. Apply manually per the F5 install guide for now; a NAD-provisioning module is a follow-up.

## Maturity

`alpha` — implements the F5 dedicated-HP-node pattern with the generic 3-interface TMM model. Has not been validated end-to-end against a live AWS account yet. Specifically the bootstrap timing (both ENIs attached before kubelet) and AL2023 device-name mapping (`device_index=2 → ens7`, `3 → ens8`) are correct per F5 + AWS docs but need a real run.

Moves to `beta` after first successful end-to-end deploy via either `-with-hp-nodes` blueprint. Moves to `1.0.0` alongside both base blueprints once everything is validated.
