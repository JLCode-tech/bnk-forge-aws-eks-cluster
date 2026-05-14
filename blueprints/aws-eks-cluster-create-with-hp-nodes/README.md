# Blueprint: AWS EKS Cluster Create + HP Nodes

Provision a brand-new AWS EKS cluster end-to-end **and** a dedicated high-performance node pool with the 3-interface TMM model (CNI / external / internal), then lay down the BNK control plane. HP variant of `aws-eks-cluster-create` — the full greenfield experience.

## What this blueprint does

| Step | Module | Status |
|---|---|---|
| 1 | `eks-cluster-create` — VPC + EKS cluster + default node group via terraform-aws-modules | Implemented (beta) |
| 2 | `eks-cluster-hp-nodes` — TMM subnets + HP managed node group + dual secondary ENIs per node | Implemented (alpha) |
| 3 | `eks-cluster-install-multus` — Multus CNI install (vendored from catalog-shared) | Implemented (alpha) |
| 4 | `eks-cluster-install-tmm-nads` — ens7/ens8 NetworkAttachmentDefinitions (AWS discovery for static addresses) | Implemented (alpha) |
| 5 | `eks-cluster-install-bnk-prereqs` — namespaces, FAR pull secrets, manifest | Implemented (vendored) |
| 6 | `eks-cluster-install-cert-manager` — Jetstack cert-manager | Implemented (vendored) |
| 7 | `eks-cluster-install-cert-issuer` — BNK CA + ClusterIssuer | Implemented (vendored) |
| 8 | `eks-cluster-install-flo` — F5 Lifecycle Operator + licence activation | Implemented |
| 9 | `eks-cluster-cneinstall` — CNEInstance CR + cloud-network-mapping + BNKGateway CR + AWS IRSA | Implemented |

Current revision: `version: 0.1.0`, `maturity: alpha`. Moves to `beta` after first successful live deploy; `1.0.0` once all four blueprints have been validated.

## What this builds in AWS

A fully provisioned greenfield deployment with TMM-ready data plane:

| Layer | Resource | Source |
|---|---|---|
| VPC + base cluster | VPC, IGW, NAT, public + private subnets across 3 AZs, EKS cluster, default node group, IRSA OIDC | `terraform-aws-modules/vpc/aws ~> 6.0` + `terraform-aws-modules/eks/aws ~> 21.0` |
| TMM data-plane infra | Per-AZ TMM-external + TMM-internal subnets (tagged `f5-bnk-role=tmm-external` / `tmm-internal`) | `modules/eks-cluster-hp-nodes` |
| HP node pool | EKS managed NG (`m5n.large`), launch template (IMDSv2, EBS-encrypted), dual secondary ENI bootstrap, `app=f5-tmm` label | `modules/eks-cluster-hp-nodes` |
| BNK control plane | namespaces, FAR secrets, cert-manager, ClusterIssuer, FLO + licence, CNEInstance + IRSA + BNKGateway | rest of catalog |

> **Note on subnet tagging:** in this variant the base `cluster-create` step is forced `tag_private_subnets_for_tmm: false`, so the *only* subnets tagged `f5-bnk-role=tmm-external` are the dedicated ones HP-nodes creates. `cneinstall`'s rediscovery then builds the BNKGateway CR exclusively from the HP subnets — clean separation.

## NetworkAttachmentDefinition prerequisite

Handled automatically by steps 3 + 4:
- `eks-cluster-install-multus` (cloud-agnostic, vendored from `bnk-forge-catalog-shared`) — applies the upstream multus-daemonset and waits for the CRD + DS rollout.
- `eks-cluster-install-tmm-nads` (AWS-specific) — discovers the f5-bnk-role-tagged TMM subnets, derives each NAD's static IPAM placeholder, applies the `ens7-ipvlan-l2` + `ens8-ipvlan-l2` NADs.

No manual apply needed.

## Inputs (differs from the base blueprint)

In addition to all inputs from `aws-eks-cluster-create`, this blueprint adds:

| Name | Default | Description |
|---|---|---|
| `hp_instance_type` | `m5n.large` | Must support ≥ 3 ENIs (primary + 2 secondary). |
| `hp_node_count_per_az` | `1` | HP nodes per AZ. |
| `hp_node_disk_size_gb` | `50` | HP root volume size. |

And changes the default of:

| Name | Base blueprint | This blueprint |
|---|---|---|
| `network_attachments` | `["ens7-ipvlan-l2"]` | `["ens7-ipvlan-l2", "ens8-ipvlan-l2"]` |
| (forced) `tag_private_subnets_for_tmm` on `cluster-create` | `true` | `false` |

## Module chain (depends_on graph)

```
cluster-create
    └─→ hp-nodes
            └─→ install-multus
            │       └─→ tmm-nads ───────────────────┐
            └─→ bnk-prereqs                         │
                    └─→ cert-manager                │
                            └─→ cert-issuer         │
                                    └─→ flo         │
                                          └─→ cneinstall  (also depends on tmm-nads)
```

## Estimated time + cost

- **Time:** 35-55 minutes end-to-end. EKS control plane ~10-15 min; default node group ~5 min; HP node pool ~5-8 min; BNK install ~15-25 min.
- **Cost:** AWS usage-based. EKS control plane (~$0.10/hr) + default node group (3× m5.large) + NAT gateway + **HP node pool (3× m5n.large ≈ $300/mo)** + EBS volumes for all of the above.

Tear down with `tofu destroy` when finished testing. After destroy, sweep any orphaned ENIs:
```bash
aws ec2 describe-network-interfaces \
  --filters "Name=tag:bnk-forge:cluster,Values=<cluster>" \
            "Name=status,Values=available" \
  --query 'NetworkInterfaces[].NetworkInterfaceId' --output text \
  | xargs -r -n1 aws ec2 delete-network-interface --network-interface-id
```

## Verifying BNK is up

```bash
# License activation in CWC
kubectl logs -n <operator_namespace> -l app.kubernetes.io/name=f5-spk-cwc \
  -c f5-spk-cwc | grep -i "Verification Complete"

# HP nodes present and labelled
kubectl get nodes -l app=f5-tmm

# TMM pods running on HP nodes
kubectl get pods -A -l app=f5-tmm -o wide

# Verify 3 interfaces inside a TMM container
kubectl exec -n <operator_namespace> <tmm-pod> -c f5-tmm -- ip a
```

The TMM container should show three interfaces: `eth0` (CNI), `net1` (ens7), `net2` (ens8). Each `net*` has an IP from the corresponding AZ-matched TMM subnet.
