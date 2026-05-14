# eks-cluster-hp-nodes

Add a dedicated high-performance EKS managed node group to an existing cluster for hosting TMM data-plane pods. Optional addition to both AWS EKS blueprints.

## When to use this module

Add this when you need TMM to actually pass traffic. The base blueprints (`aws-eks-cluster-existing` and `aws-eks-cluster-create`) provision a cluster + the BNK control plane, but TMM pods need:

1. Nodes labelled `app=f5-tmm` (so FLO schedules TMM on them).
2. A second ENI in a "TMM-external" subnet — the data-plane interface that VPC CNI must ignore (`node.k8s.amazonaws.com/no_manage=true`).
3. NetworkAttachmentDefinition (`ens7-ipvlan-l2` by default) that binds to that second ENI.

This module covers #1 and #2 declaratively. #3 is part of the BNK manifest applied by `bnk-prereqs`.

## What it builds

| Resource | Purpose |
|---|---|
| `aws_subnet.tmm[*]` | One per AZ. Tagged `f5-bnk-role=tmm-external` so `cneinstall` auto-builds the BNKGateway CR. |
| `aws_iam_role.hp_node` + worker/CNI/registry policies | Standard EKS node role. |
| `aws_iam_role_policy.hp_node_eni` (inline) | Scoped ENI-management permissions — `CreateNetworkInterface`, `AttachNetworkInterface`, `ModifyNetworkInterfaceAttribute`, `AssignPrivateIpAddresses`, `CreateTags`. Used by the bootstrap script. |
| `aws_launch_template.hp` | IMDSv2-required, EBS-encrypted, custom user-data. MIME-multipart so EKS's own bootstrap still runs. |
| `aws_eks_node_group.hp` | Dedicated managed NG. Default `m5n.large` (SR-IOV + 100Gbps ENA), `app=f5-tmm` label, optional taints. |

## How the secondary ENI bootstraps

`manifests/launch-template-userdata.sh.tftpl` runs on first boot inside each HP node. It:

1. Reads IMDSv2 for instance ID + AZ + region.
2. Picks the AZ-matching TMM subnet from a Terraform-rendered map.
3. `aws ec2 create-network-interface` in that subnet, tagged `node.k8s.amazonaws.com/no_manage=true` so AWS VPC CNI leaves it alone.
4. `aws ec2 attach-network-interface --device-index 2` (→ `ens7` on AL2023).
5. `modify-network-interface-attribute` to set `DeleteOnTermination=true` so the ENI doesn't leak when the ASG cycles the instance.
6. Polls `ip link` until the kernel registers the new interface — gives the kubelet a clean device list when it starts.

The MIME-multipart format wraps this so EKS's own bootstrap (kubelet bring-up, cluster join) runs after ours.

Default `device_index = 2` matches the `ens7` device name and the standard `NetworkAttachmentDefinition` (`master: ens7`). Override `secondary_eni_device_index` only if you've also overridden the NAD.

## Inputs

| Name | Source | Required | Default | Description |
|---|---|---|---|---|
| `aws_*` creds | AWS credential template | Yes | — | Any of Forge's three auth methods (`access_keys` / `profile` / `sso`). |
| `aws_region` | User / project | Yes | — | Region. |
| `eks_cluster_name` | Upstream module | Yes | — | Cluster to attach the HP NG to. Auto-wired from `cluster-register` or `cluster-create`. |
| `vpc_id` | Upstream module | Yes | — | Cluster VPC. |
| `vpc_cidr` | Upstream module | Yes | — | For auto-carving TMM subnets when `tmm_subnet_cidrs` is empty. |
| `availability_zones` | Upstream module | Yes | — | AZs to spread HP nodes across. |
| `node_subnet_ids` | Upstream module | Yes | — | Where the HP node group places its **primary** ENI. Auto-wires from the upstream cluster module's `subnet_ids` (register) or `private_subnet_ids` (create). |
| `tmm_subnet_cidrs` | User | No | `[]` → auto-carve | Override per-AZ TMM subnet CIDRs. |
| `tmm_subnet_newbits` | User | No | `8` | `cidrsubnet()` newbits when auto-carving. |
| `tmm_subnet_index_offset` | User | No | `200` | Subnet index offset to avoid colliding with worker subnets. |
| `instance_type` | User | No | `m5n.large` | EC2 type. SR-IOV-capable. |
| `node_count_per_az` | User | No | `1` | Set `0` to skip the NG entirely (subnets still created). |
| `node_disk_size_gb` | User | No | `50` | Root volume. |
| `secondary_eni_device_index` | User | No | `2` | Bootstrapped ENI device index. |
| `additional_ips_per_eni` | User | No | `0` | Extra IPs on the secondary ENI at creation. `0` = let cneinstall's IPAM manage. |
| `node_label_app` | User | No | `f5-tmm` | `app=<this>` label on HP nodes. |
| `node_taints` | User | No | `[]` | Optional taints to dedicate the pool. |
| `tag_subnets_for_tmm` | User | No | `true` | Tag TMM subnets `f5-bnk-role=tmm-external` for cneinstall auto-discovery. |

## Outputs

| Output | Used by |
|---|---|
| `tmm_subnet_ids`, `tmm_subnet_ids_by_az`, `tmm_subnet_cidrs` | Cross-referencing |
| `tmm_external_subnets_by_az` | `cneinstall` — override its same-named input when chaining HP-nodes ahead of cneinstall to point the BNKGateway CR at these subnets. |
| `hp_node_group_arn`, `hp_node_group_name`, `hp_node_count`, `hp_node_role_arn`, `launch_template_id` | Diagnostics, downstream IRSA |

## Cost considerations

This module adds material AWS cost on top of the base cluster:

- 3× HP nodes (default `m5n.large` ≈ $0.14/hr each = ~$300/mo).
- Secondary ENIs (free, but each one consumes a private IP from the TMM subnet).
- TMM subnets (no cost themselves; reserve VPC IP space).

For pre-production validation use `node_count_per_az = 0` to validate the subnet + IAM + LT plumbing without spinning real nodes.

## Known limitations

- **Destroy-time orphans.** ENIs created by the bootstrap script are marked `DeleteOnTermination=true`, so they go away when the EC2 instance terminates. But if a manual `aws ec2 detach-network-interface` ran beforehand, or the cluster's VPC CNI somehow grabbed the ENI before our tag landed, the ENI may leak. After `tofu destroy` run a quick cleanup:
  ```bash
  aws ec2 describe-network-interfaces \
    --filters "Name=tag:bnk-forge:cluster,Values=<cluster>" \
              "Name=status,Values=available" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' \
    --output text \
    | xargs -r -n1 aws ec2 delete-network-interface --network-interface-id
  ```
- **First-boot race.** If the AWS API is slow, the kubelet may start before the ENI is registered by the kernel. The user-data polls `ip link` for up to 30s; bump that loop if your region is flaky.
- **AMI release version.** Default = latest stable AL2023 for the cluster's K8s minor. Pin via `eks_ami_release_version` if you need byte-for-byte reproducible nodes.
- **Taints opt-in.** No taints by default — TMM pods land here via `app=f5-tmm` label match, but other pods may also land here. Add taints to lock the pool.

## Maturity

`alpha` — implements the F5 dedicated-HP-node pattern but has not yet been validated end-to-end against a live AWS account. Specifically the user-data bootstrap timing (ENI attach before kubelet) and the AL2023 device-name mapping (`device_index=2 → ens7`) are correct on paper from F5/AWS docs but need a real run.

Moves to `beta` after a successful end-to-end deploy. Moves to `1.0.0` after the same checks both blueprints need.
