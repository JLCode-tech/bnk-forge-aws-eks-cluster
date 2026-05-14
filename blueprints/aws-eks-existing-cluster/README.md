# Blueprint: AWS EKS Existing Cluster

Adopt an existing AWS EKS cluster into BNK Forge and lay down the shared BNK k8s prerequisites.

## What this blueprint does today

| Step | Module | Status |
|---|---|---|
| 1 | `eks-cluster-register` — discover and adopt an existing EKS cluster | Implemented |
| 2 | `eks-cluster-install-bnk-prereqs` — namespaces, FAR pull secrets, manifest | Implemented (vendored from `bnk-forge-catalog-shared`) |
| 3 | `eks-cluster-install-cert-manager` — install Jetstack cert-manager | Implemented (vendored) |
| 4 | `eks-cluster-install-cert-issuer` — BNK CA + ClusterIssuer | Implemented (vendored) |
| 5 | `eks-cluster-install-flo` — install F5 Lifecycle Operator via Helm (AWS-tuned values) | Implemented |
| 6 | `eks-cluster-cneinstall` — CNEInstance CR + cloud-network-mapping + BNKGateway CR + AWS IRSA | Implemented |
| 7 | `eks-cluster-license` — apply the BNK License CR | Not yet implemented |

Current revision: `version: 0.4.0`, `maturity: preview`. The License module is the last remaining step — once that lands this blueprint will deploy BNK end-to-end onto an existing EKS cluster.

## Inputs (current revision)

| Name | Source | Required | Description |
|---|---|---|---|
| `aws_access_key_id` | AWS credential template | Yes | AWS access key ID. |
| `aws_secret_access_key` | AWS credential template | Yes | AWS secret access key. |
| `aws_region` | AWS credential template / project | Yes | Region where the cluster resides. |
| `eks_cluster_name` | User | Yes | Name of the existing EKS cluster. |
| `cne_pull_secret` | Project secret | Yes | Base64-encoded F5 FAR registry credentials. |
| `jwt_token` | Project secret | Yes | F5 BNK License JWT. |
| `aws_session_token` | AWS credential template | No | STS session token for assumed-role credentials. |
| `operator_namespace` | User | No | Namespace for FLO and BNK components. Default `f5-operator`. |
| `utils_namespace` | User | No | Namespace for utility components. Default `f5-utils`. |
| `gateway_namespace` | User | No | Namespace for Gateway API resources. Default `bnk-gw`. |
| `bnk_manifest_version` | User | No | BNK manifest version to download. Default `2.2.1-3.2226.0-0.0.511`. |
| `license_mode` | User | No | FLO license mode: `connected` (default) or `f5licenseproxy`. |
| `container_platform` | User | No | FLO containerPlatform. Default `AWS`. |
| `deployment_size` | User | No | CNEInstance size: Small/Medium/Large. Default `Small`. |
| `tmm_replicas` | User | No | Number of TMM replicas. Default `0` = auto: `min(cluster AZ count, worker node count)`. |
| `watch_namespaces` | User | No | Namespaces the CNE controller watches. Default `["All"]`. |
| `network_attachments` | User | No | NAD names attached to TMM. Default `["ens7-ipvlan-l2"]`. |
| `vip_cidr` | User | **For Gateway-API traffic** | CIDR carved from your VPC (or a TMM external AZ subnet) for BNK Gateway VIPs (e.g. `192.168.250.0/24`). Empty = skip the BNKGateway CR; required if you want Gateway/HTTPRoute traffic to flow. |

> **`cloud_az_subnet_mappings`, `availability_zone_count`, `worker_node_count`, `vpc_cidr`** are all auto-wired from `eks-cluster-register`. The register module queries the EKS cluster's own VPC + node group config and exposes them so `cneinstall` can compute sensible defaults (the tmm_replicas auto-default uses both AZ and node counts). Users don't see or set these — EKS already knows them.

## Cluster admin prerequisite (manual)

Before deploying, label the nodes you want to host TMM pods:

```bash
kubectl label node <node-name> app=f5-tmm
```

FLO places TMM pods on nodes carrying this label. The `tmm_replicas` auto-default (1 per AZ, capped by worker count) only works if enough nodes are labeled. For a 3-AZ cluster with one node per AZ, label all three.

## Module chain (depends_on graph)

```
cluster-register
    └─→ bnk-prereqs
            └─→ cert-manager
                    └─→ cert-issuer
                            └─→ flo
                                    └─→ cneinstall
```

## What you get

After apply:

- BNK Forge auto-registers the cluster in the Kubernetes inventory using `cluster_name`, `cluster_id` (ARN), `cluster_endpoint`, `region`, and the emitted `kubeconfig`.
- BNK namespaces (`f5-operator`, `f5-utils`, `bnk-gw`) and FAR image pull secrets exist on the cluster.
- The BNK component manifest has been downloaded and parsed — component versions are available for downstream FLO install.
- Jetstack cert-manager is installed and healthy.
- The BNK CA + CA-backed ClusterIssuer is ready for use by FLO and OTEL certificate flows.
- F5 Lifecycle Operator is installed with AWS-tuned defaults; BNK CRDs (`F5SPKVlan`, `CNEInstance`, `BNKNetPolicy`, etc.) are registered with the cluster API.
- CNEInstance CR is applied with AWS production defaults — FLO rolls out CWC, DSSM, OTEL, RabbitMQ, TMM, and the IPAM operator.
- AWS IRSA is wired for the CNE controller: IAM role with EC2 VIP permissions, SA annotated, controller restarted.
- (When configured) cloud-network-mapping ConfigMap and BNKGateway CR (`kind: F5BnkGateway`) are applied so the CNE controller can compute multi-AZ TMM placement and Gateway/HTTPRoute translation works.

## What's still required to deploy BNK end-to-end

Until the License module ships in this repo, run that step manually after this blueprint applies. Or wait for the next PR.
