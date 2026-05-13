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
| `tmm_replicas` | `3` | One per AZ typical for multi-AZ. |
| `watch_namespaces` | `["All"]` | Which namespaces the controller watches. |
| `network_attachments` | `["ens7-ipvlan-l2"]` | NAD names attached to TMM. Matches the future `network-setup` module's default NAD. |
| `storage_class_name` | `gp3` | EKS gp3 is the AWS default. |
| `bnk_gateway_chassis` | `{ default_listener_networks = [] }` | F5BnkGateway chassis config. Set this if you want Gateway/HTTPRoute traffic to flow. |

`cloud_az_subnet_mappings` is no longer a user-facing input — it's auto-wired from `eks-cluster-register`. The register module queries the cluster's VPC config via `data.aws_eks_cluster.vpc_config.subnet_ids` + `data.aws_subnet` to discover AZs and CIDRs, and exposes the structured mapping that this module consumes directly.

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

## Reference

- [F5 CNEInstance docs](https://clouddocs.f5.com/bigip-next-for-kubernetes/latest/spk-custom-resources.html)
- [EKS IRSA docs](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
