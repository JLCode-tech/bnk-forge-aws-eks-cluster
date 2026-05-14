# Blueprint: AWS EKS Existing Cluster

Install the BNK 2.2 platform onto an existing AWS EKS cluster.

## Prerequisites

- An existing AWS EKS cluster reachable from the project.
- AWS credential template (any of Forge's 3 auth methods: access_keys / profile / sso).
- Project secret `cne_pull_secret` — base64 F5 FAR registry credentials.
- Project secret `jwt_token` — F5 BNK License JWT.

## Inputs

The deploy form asks for **one thing the user actually types**: `eks_cluster_name`. Everything else (AWS creds, region) is auto-filled from the project's credential template; FAR pull secret and licence JWT come from project secrets, not the form.

| Field | Default | When to change |
|---|---|---|
| `vip_cidr` | empty → auto-discover | If your VIPs live outside the f5-bnk-role=tmm-external subnets |
| `tmm_replicas` | 0 → auto | Set explicitly to override the AZ × node-count auto-derivation |
| `deployment_size` | `Small` | `Medium` / `Large` / `Max` per F5 sizing docs |

## What it does

| Step | Module |
|---|---|
| 1 | `eks-cluster-register` — adopt the cluster |
| 2 | `eks-cluster-install-bnk-prereqs` — namespaces, FAR pull secrets, manifest |
| 3 | `eks-cluster-install-cert-manager` — Jetstack cert-manager |
| 4 | `eks-cluster-install-cert-issuer` — BNK CA + ClusterIssuer |
| 5 | `eks-cluster-install-flo` — FLO + BNK CRDs + licence activation |
| 6 | `eks-cluster-cneinstall` — CNEInstance + IRSA + BNKGateway CR |

## Verifying

```bash
kubectl logs -n f5-operator -l app.kubernetes.io/name=f5-spk-cwc -c f5-spk-cwc | grep "Verification Complete"
kubectl get cneinstance -A
```

## Other variants

- **`aws-eks-cluster-create`** — provision a new cluster instead of adopting.
- **`aws-eks-existing-cluster-with-hp-nodes`** — same install + dedicated HP TMM node pool with 3-interface model.
- **`aws-eks-cluster-create-with-hp-nodes`** — full greenfield, including HP nodes.
