# Blueprint: AWS EKS Existing Cluster + HP Nodes

Adopt an existing AWS EKS cluster, add a dedicated **high-performance node pool** with the 3-interface TMM model (CNI / external / internal), and lay down the BNK control plane on top. HP variant of `aws-eks-existing-cluster`.

## What this blueprint does

| Step | Module | Status |
|---|---|---|
| 1 | `eks-cluster-register` — adopt an existing EKS cluster | Implemented |
| 2 | `eks-cluster-hp-nodes` — TMM subnets + HP managed node group + dual secondary ENIs per node | Implemented (alpha) |
| 3 | `eks-cluster-install-bnk-prereqs` — namespaces, FAR pull secrets, manifest | Implemented (vendored) |
| 4 | `eks-cluster-install-cert-manager` — Jetstack cert-manager | Implemented (vendored) |
| 5 | `eks-cluster-install-cert-issuer` — BNK CA + ClusterIssuer | Implemented (vendored) |
| 6 | `eks-cluster-install-flo` — F5 Lifecycle Operator + licence activation | Implemented |
| 7 | `eks-cluster-cneinstall` — CNEInstance CR + cloud-network-mapping + BNKGateway CR + AWS IRSA | Implemented |

Current revision: `version: 0.1.0`, `maturity: alpha`. Moves to `beta` after a first successful live deploy; `1.0.0` once all four blueprints (existing/create × with/without HP) have been validated.

## Why this variant exists

Same install chain as `aws-eks-existing-cluster`, but step 2 adds the data-plane infrastructure TMM actually needs:

- Per-AZ TMM-external + TMM-internal subnets (tagged `f5-bnk-role=tmm-external` / `tmm-internal`)
- Dedicated HP managed node group with `app=f5-tmm` label
- Each HP node attaches two secondary ENIs at first boot (`ens7` external on TMM-ext subnet, `ens8` internal on TMM-int subnet), tagged `node.k8s.amazonaws.com/no_manage=true` so VPC CNI ignores them

Without this step, TMM pods on a default-pool node only have the primary CNI interface — no data-plane separation.

## NetworkAttachmentDefinition prerequisite

`ens7-ipvlan-l2` and `ens8-ipvlan-l2` NADs must exist on the cluster before TMM pods can start. Apply them manually per the F5 multi-node BNK on AWS/EKS install guide until a dedicated NAD-provisioning module ships:

```yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ens7-ipvlan-l2
spec:
  config: '{"cniVersion":"0.3.1","type":"ipvlan","master":"ens7","mode":"l2","ipam":{"type":"static"}}'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ens8-ipvlan-l2
spec:
  config: '{"cniVersion":"0.3.1","type":"ipvlan","master":"ens8","mode":"l2","ipam":{"type":"static"}}'
```

## Inputs (differs from the base blueprint)

In addition to all inputs from `aws-eks-existing-cluster`, this blueprint adds:

| Name | Default | Description |
|---|---|---|
| `hp_instance_type` | `m5n.large` | Must support ≥ 3 ENIs (primary + 2 secondary). m5n.large is the minimum; m5n.xlarge/c5n.xlarge give more room. |
| `hp_node_count_per_az` | `1` | HP nodes per AZ. Total = this × AZ count. |
| `hp_node_disk_size_gb` | `50` | HP root volume size. |

And changes the default of:

| Name | Base blueprint | This blueprint |
|---|---|---|
| `network_attachments` | `["ens7-ipvlan-l2"]` | `["ens7-ipvlan-l2", "ens8-ipvlan-l2"]` |

## Cluster admin prerequisite (manual)

No node-labelling needed — HP-nodes labels the new pool automatically with `app=f5-tmm`. Just make sure your existing cluster has at least the AZ spread you want HP nodes to fill (default 3).

## Module chain (depends_on graph)

```
cluster-register
    └─→ hp-nodes
            └─→ bnk-prereqs
                    └─→ cert-manager
                            └─→ cert-issuer
                                    └─→ flo
                                            └─→ cneinstall
```

## Estimated time + cost

- **Time:** 25-40 minutes end-to-end. HP node pool ~5-8 min; remaining install chain ~15-25 min.
- **Cost:** AWS usage-based, **adds ~3× m5n.large nodes** ($0.14/hr each ≈ $300/mo) plus 6 secondary ENIs on top of your existing cluster cost.

## Verifying BNK is up

After apply succeeds:

```bash
# License activation in CWC
kubectl logs -n <operator_namespace> -l app.kubernetes.io/name=f5-spk-cwc \
  -c f5-spk-cwc | grep -i "Verification Complete"

# HP nodes labelled correctly
kubectl get nodes -l app=f5-tmm

# TMM pods running on HP nodes
kubectl get pods -A -l app=f5-tmm -o wide
```

A TMM pod should have **three interfaces**: `eth0` (CNI), `net1` (ens7-ipvlan-l2 → external), `net2` (ens8-ipvlan-l2 → internal). Verify inside a TMM container:

```bash
kubectl exec -n <operator_namespace> <tmm-pod> -c f5-tmm -- ip a
```
