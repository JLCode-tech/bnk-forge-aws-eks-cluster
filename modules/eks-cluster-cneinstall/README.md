# eks-cluster-cneinstall

Apply the CNEInstance CR on AWS EKS, lay down AWS-specific supporting resources, and wire IRSA for the CNE controller. All-in-one — single module, no separate IRSA stage.

## What runs (in order)

| Step | Action | Conditional |
|---|---|---|
| 1 | Render + apply the `cloud-network-mapping` ConfigMap with AWS AZ → subnet mapping. The CNE controller reads it for multi-AZ TMM placement. The AZ/subnet list is **auto-wired** from `eks-cluster-register.cloud_az_subnet_mappings` — discovered from the EKS cluster's own VPC config, so users don't have to re-enter what EKS already knows. | Skipped only if the EKS cluster returns no subnets (shouldn't happen in practice). |
| 2 | Render + apply the `CNEInstance` CR with AWS-tuned production defaults. FLO observes the CR and rolls out CWC, DSSM, Observer, OTEL, RabbitMQ, TMM, and the IPAM operator. | Always |
| 3 | Render + apply the `F5BnkGateway` chassis CR (required on AWS/EKS for Gateway-API translation — see [bnk-forge-modules PR #58](https://github.com/JLCode-tech/bnk-forge-modules/pull/58) for the discovery trail). | Skipped if `bnk_gateway_chassis.default_listener_networks` is empty. |
| 4 | Create IAM policy (`<cluster>-allow-ec2-vip`) + IRSA role (`<cluster>-cne-controller-vip`) with OIDC trust scoped to the CNE controller's SA. | Always |
| 5 | Wait for FLO to create the CNE controller SA (up to `wait_for_sa_timeout_seconds`), annotate it with `eks.amazonaws.com/role-arn`, rollout-restart the deployment. | Always |

## CNEInstance CR — what's baked vs configurable

**Baked into the template** (AWS production defaults, not user-overridable):

| Setting | Value | Why baked |
|---|---|---|
| `product.type` | `BNK` | The CR is BNK by definition. |
| `product.gatewayAPI` | `true` | Required for Gateway-API translation. |
| `wholeCluster` | `false` | Per-namespace watching is the AWS pattern. |
| `telemetry.{logging,metric}Subsystem.enabled` | `true` | Production telemetry. |
| `dynamicRouting.enabled` | `true` | BGP/dynamic routing on. |
| `firewallACL.enabled` | `false` | Off by default; users opt into BNKSecPolicy later if needed. |
| `pseudoCNI.enabled` | `true` | Required for TMM ENI binding on AWS. |
| `coreCollection.enabled` | `true` | TMM core dumps on. |
| `advanced.coremon.hostPath` | `true` | AWS host-path collection. |
| `advanced.envDiscovery.*` | enabled, stopOnFail, runAfterSuccess | Production env discovery flow. |
| `advanced.demoMode.enabled` | `false` | Production. |
| `advanced.maintenanceMode.enabled` | `false` | Production. |
| `advanced.cneController.env` | `CLOUD_ENV=true`, `CLOUD_PROVIDER=aws`, `CLOUD_NETWORK_CONFIGMAP=cloud-network-mapping`, `TMM_DEFAULT_MTU=9000` | AWS-specific controller env. |
| `advanced.tmm.env` | `TMM_DEFAULT_MTU=9000`, `PAL_CPU_SET=0,2`, `TMM_MAPRES_ADDL_VETHS_ON_DP=TRUE` | AWS-tuned TMM env. |
| `registry.uri` | `repo.f5.com` | F5 official registry. |
| `registry.imagePullPolicy` | `Always` | Avoid stale caching during BNK release cuts. |

**Exposed as blueprint inputs** (user can override at deploy time):

| Input | Default | Description |
|---|---|---|
| `instance_name` | `default-f5-cne-controller` | CR name. |
| `deployment_size` | `Small` | `Small` / `Medium` / `Large`. |
| `tmm_replicas` | `0` | `0` = auto-derive `min(availability_zone_count, worker_node_count)` from cluster-register's outputs. Set a positive number to override. |
| `watch_namespaces` | `["All"]` | Which namespaces the controller watches. |
| `network_attachments` | `["ens7-ipvlan-l2"]` | NAD names attached to TMM. Matches the future `network-setup` module's default NAD. |
| `storage_class_name` | `gp3` | EKS gp3 is the AWS default. |
| `vip_cidr` | `""` | CIDR for BNK Gateway VIPs. Module computes `start_address = cidrhost(vip_cidr, 1)`, `end_address = cidrhost(vip_cidr, -2)` for the F5BnkGateway chassis CR. Empty = skip chassis CR. |
| `chassis_name`, `vip_network_name` | `bnk-gateway-chassis`, `default` | F5BnkGateway CR + listener-network names. Rarely changed. |
`cloud_az_subnet_mappings`, `availability_zone_count`, `worker_node_count`, `vpc_cidr` are not user-facing inputs — they're auto-wired from `eks-cluster-register` via `data.aws_eks_cluster` + `data.aws_subnet` + `data.aws_vpc` + `data.aws_eks_node_group`.

## Cluster admin prerequisite (manual)

FLO places TMM pods on nodes carrying the `app=f5-tmm` Kubernetes label. Label the appropriate nodes before deploy:

```bash
kubectl label node <node-name> app=f5-tmm
```

For a 3-AZ cluster the typical pattern is one TMM-eligible node per AZ. The `tmm_replicas = 0` auto-default expects this — if fewer nodes are labeled than the auto-default computes, TMM pods will stay Pending until labels are added or `tmm_replicas` is overridden.

Future work: a tag-based discovery convention on EKS node groups would let this module compute `tmm_replicas` from the count of TMM-tagged nodes specifically (rather than total worker count). Not implemented yet — F5 hasn't documented a node-group tag convention; the manual `kubectl label` step is the documented placement mechanism.

## IRSA — what gets granted

The CNE controller needs to attach VIPs / selfips as secondary IPs on TMM's data-plane ENIs. This module creates an IAM role with these EC2 permissions:

```
ec2:AssignPrivateIpAddresses
ec2:UnassignPrivateIpAddresses
ec2:DescribeInstances
ec2:DescribeNetworkInterfaces
```

The trust policy binds the role to the cluster's OIDC provider, scoped to the controller's SA (`system:serviceaccount:<operator_namespace>:<cne_controller_sa_name>`).

Extra managed policies can be attached via `extra_irsa_managed_policy_arns`.

## Inputs — quick reference

Auto-wired from upstream modules in the blueprint chain:

| Input | Source |
|---|---|
| `eks_cluster_name`, `cluster_oidc_issuer_url`, `cloud_az_subnet_mappings` | `eks-cluster-register` |
| `operator_namespace`, `manifest_version`, `far_secret_name` | `eks-cluster-install-bnk-prereqs` |
| `cluster_issuer_name` | `eks-cluster-install-cert-issuer` |
| `flo_ready`, `crds_installed` | `eks-cluster-install-flo` (gates) |

User-supplied via credential template:

| Input | Source |
|---|---|
| `aws_access_key_id`, `aws_secret_access_key`, `aws_session_token` | AWS credential template (any auth method) |
| `aws_region` | Project region |

User-supplied directly:

See the table above under "Exposed as blueprint inputs".

## Outputs

| Output | Used by |
|---|---|
| `cneinstance_namespace`, `cneinstance_ready` | `eks-cluster-license` (downstream gate) |
| `cne_controller_role_arn` | (reference / future modules) |
| `cloud_network_mapping_applied`, `bnk_gateway_chassis_applied` | Diagnostic outputs — confirm conditional resources ran |

## Provenance

Three sources merged for this module:

1. [`JLCode-tech/bnk-forge-modules/bnk/cneinstance`](https://github.com/JLCode-tech/bnk-forge-modules/tree/release/2.2/bnk/cneinstance) — CR template baseline + kubectl-apply pattern.
2. [`JLCode-tech/bnk-forge-modules/infra/aws/cne-irsa`](https://github.com/JLCode-tech/bnk-forge-modules/tree/release/2.2/infra/aws/cne-irsa) — IRSA wiring (IAM policy + role + annotate-and-restart dance).
3. F5 internal *Multinode BNK Deployment in AWS/EKS (FLO)* install guide — AWS-specific CR values (CLOUD_ENV vars, MTU=9000, PAL_CPU_SET=0,2, cloud-network-mapping ConfigMap shape).

Plus the F5BnkGateway chassis logic from [`bnk-forge-modules` PR #58](https://github.com/JLCode-tech/bnk-forge-modules/pull/58) — note that PR is still open in the legacy repo; we adopt its pattern here.

This module is **not** part of the auto-refresh flow from `bnk-forge-catalog-shared`. Updates require manual diff against the upstream sources for each new BNK release.

## Documentation status of the AWS-specific bits

Verified 2026-05-14 against [F5 CloudDocs CNEInstance CR parameters (BNK 2.2)](https://clouddocs.f5.com/bigip-next-for-kubernetes/2.2/cneinstance-parameters.html):

**Documented in F5 public docs ✓**
- `spec.tmmReplicas` (default `1` per docs; we override to `0` = auto-from-AZ-count)
- `spec.networkAttachments`
- `spec.deploymentSize` valid values: `Small` / `Medium` / `Large` / `Max`
- `spec.registry.{uri, imagePullSecrets, imagePullPolicy}`
- `spec.{dynamicRouting, pseudoCNI, firewallACL, coreCollection}.enabled` (all default `true` per docs)
- `spec.advanced.{cneController, tmm}.env.items` — the *structure* for env vars is documented; individual values below are not

**NOT in F5 public docs (sourced from F5's internal AWS install guide):**

| Setting | Where it's documented | Risk |
|---|---|---|
| `cneController.env.CLOUD_ENV=true` | F5 multi-node BNK AWS install guide (internal) | Behavior may change without notice |
| `cneController.env.CLOUD_PROVIDER=aws` | Same | Same |
| `cneController.env.CLOUD_NETWORK_CONFIGMAP=cloud-network-mapping` | Same | Same |
| `cneController.env.TMM_DEFAULT_MTU=9000` | Same | Same |
| `tmm.env.PAL_CPU_SET=0,2` | Same | Same |
| `tmm.env.TMM_MAPRES_ADDL_VETHS_ON_DP=TRUE` | Same | Same |
| `cloud-network-mapping` ConfigMap (separate resource the controller reads) | Internal install guide only | Required for AWS multi-AZ TMM placement |
| F5BnkGateway chassis CR (`apiVersion: k8s.f5net.com/v1`) | Not in F5 public docs — discovery trail in [bnk-forge-modules PR #58](https://github.com/JLCode-tech/bnk-forge-modules/pull/58) | Behavior tied to `f5ingress` controller version; required on AWS/EKS as of `v14.19.4-0.1.36` |

These settings are **load-bearing for AWS deployments** but customers won't find them in the public CR reference. When BNK ships a new release, re-verify the AWS install guide and the F5BnkGateway controller behavior haven't changed shape.

**Opinionated default that diverges from F5 docs:**
- `spec.firewallACL.enabled = false` — F5's CRD default is `true`, but the AWS install guide explicitly sets it to `false` (customer opts in via BNKSecPolicy CR later). We follow the AWS install guide.

## Reference

- [F5 CNEInstance CR parameters (BNK 2.2)](https://clouddocs.f5.com/bigip-next-for-kubernetes/2.2/cneinstance-parameters.html)
- [F5 BNK install overview](https://clouddocs.f5.com/bigip-next-for-kubernetes/latest/bnk-install-bnk.html)
- [Configure Node Label for TMM (F5 docs — `app=f5-tmm` label)](https://clouddocs.f5.com/bigip-next-for-kubernetes/2.0.0-LA/node-label.html)
- [EKS IRSA docs](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
