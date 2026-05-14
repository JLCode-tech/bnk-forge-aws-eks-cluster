# Blueprint: AWS EKS Cluster Create + HP Nodes

Provision a brand-new AWS EKS cluster **and** a dedicated HP TMM node pool with the 3-interface TMM model, then install the BNK 2.2 platform.

The full greenfield experience.

## Prerequisites

- AWS credential template (any of Forge's 3 auth methods). Principal needs VPC + EKS + IAM create privileges.
- Project secret `cne_pull_secret`, project secret `jwt_token`.

## Inputs

User types: `eks_cluster_name`. AWS creds / region auto-fill.

| Field | Default | Notes |
|---|---|---|
| `worker_instance_type`, `worker_count_per_az` | `m5.large`, `1` | Default node group (control plane workloads) |
| `hp_instance_type`, `hp_node_count_per_az` | `m5n.large`, `1` | HP TMM nodes (data plane) — must support 3 ENIs |
| `vip_cidr`, `tmm_replicas`, `deployment_size` | auto / 0 / Small | |

## What it builds in AWS

- 1× VPC (`10.0.0.0/16`), IGW, single NAT, 3× private + 3× public subnets, default-pool EKS NG (`m5.large` × 3)
- Per-AZ TMM-external + TMM-internal subnets, HP NG (`m5n.large` × 3 by default), dual secondary ENIs per HP node
- Multus CNI + `ens7-ipvlan-l2` + `ens8-ipvlan-l2` NADs
- Full BNK install chain on top

## Cost

EKS control plane + default NG (3× `m5.large`) + NAT + HP NG (3× `m5n.large` ≈ $300/mo) + EBS volumes.

After destroy, sweep any orphaned ENIs:
```bash
aws ec2 describe-network-interfaces \
  --filters "Name=tag:bnk-forge:cluster,Values=<cluster>" \
            "Name=status,Values=available" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text \
  | xargs -r -n1 aws ec2 delete-network-interface --network-interface-id
```

## Variants

- **`aws-eks-cluster-create`** — same greenfield cluster, no HP node pool.
- **`aws-eks-existing-cluster-with-hp-nodes`** — adopt an existing cluster + add HP nodes.
