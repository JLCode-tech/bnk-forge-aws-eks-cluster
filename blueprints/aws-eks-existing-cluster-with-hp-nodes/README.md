# Blueprint: AWS EKS Existing Cluster + HP Nodes

Adopt an existing AWS EKS cluster, add a dedicated **HP TMM node pool** with the 3-interface TMM model (CNI + ens7 external + ens8 internal), and install the BNK 2.2 platform.

## When to pick this over `aws-eks-existing-cluster`

You want TMM data-plane traffic on dedicated, SR-IOV-capable nodes with two secondary ENIs (external + internal) instead of running TMM on existing cluster nodes with whatever interfaces happen to be available.

## Prerequisites

- An existing AWS EKS cluster reachable from the project.
- AWS credential template (any of Forge's 3 auth methods).
- Project secret `cne_pull_secret`, project secret `jwt_token`.

## Inputs

User types: `eks_cluster_name`. AWS creds / region auto-fill.

| Field | Default | Notes |
|---|---|---|
| `hp_instance_type` | `m5n.large` | Must support 3 ENIs (primary + 2 secondary) |
| `hp_node_count_per_az` | `1` | Total HP nodes = this × AZ count |
| `vip_cidr`, `tmm_replicas`, `deployment_size` | auto / 0 / Small | |

## What it builds on top

| Step | Module |
|---|---|
| `hp-nodes` | Per-AZ TMM-external + TMM-internal subnets, dedicated NG (`m5n.large`), dual secondary ENIs per node, `app=f5-tmm` label |
| `install-multus` | Multus CNI (vendored from catalog-shared) |
| `tmm-nads` | `ens7-ipvlan-l2` + `ens8-ipvlan-l2` NetworkAttachmentDefinitions |

Then the standard BNK install chain runs on top, using the HP nodes for TMM placement.

## Cost

Adds ~3× `m5n.large` nodes (≈ $300/mo) on top of your existing cluster.

## Variants

- **`aws-eks-existing-cluster`** — same install, no HP node pool (TMM on existing cluster nodes).
- **`aws-eks-cluster-create-with-hp-nodes`** — greenfield, includes cluster provisioning.
