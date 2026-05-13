# eks-cluster-install-flo

Install F5 Lifecycle Operator (FLO) on AWS EKS via the official F5 Helm chart from `oci://repo.f5.com/charts/f5-lifecycle-operator`.

FLO is the BNK control-plane operator. Once installed, applying a CNEInstance CR (next module in the chain) makes FLO deploy CWC, DSSM, Observer, OTEL, RabbitMQ, TMM, and the F5 IPAM operator — and register every BNK CRD with the cluster API.

## AWS-tuned defaults

The Helm install itself is cloud-agnostic, but the `values.yaml` here ships with AWS-specific defaults derived from the F5 multi-node BNK on AWS/EKS install guide:

| Value | Setting | Why AWS-specific |
|---|---|---|
| `containerPlatform` | `AWS` (override default) | Enables FLO's cloud-aware gRPC and networking behavior. |
| `fluentbit_sidecar.enabled` | `false` | The fluentbit sidecar is disabled on AWS deployments. |
| `f5-ipam-operator.namespace` | `default` | AWS convention runs the IPAM operator in `default` for predictable name + DNS. |
| `f5-ipam-operator.nameOverride` / `fullnameOverride` | `f5-ipam-operator` | Stable service name that CNEInstance + BNK CRs reference. |
| `f5-spk-crds-{common,service-proxy}.versionValidator.image.repository` | `repo.f5.com/images` | Pulls validator init images from F5's registry. |
| `image.pullPolicy` | `Always` | Avoid stale image caching during BNK release cuts. |

## What's *not* in this module (but is still AWS-specific)

Two AWS-specific things commonly confused as FLO concerns — they go in different modules:

| Concern | Where it lives | Why |
|---|---|---|
| `CLOUD_ENV`, `CLOUD_PROVIDER=aws`, `CLOUD_NETWORK_CONFIGMAP` | **CNEInstance CR** under `spec.advanced.cneController.env` — applied by the `eks-cluster-cneinstall` module | These are CNE *controller* env vars, set when the CR is applied, not on the FLO operator itself. |
| `node.k8s.amazonaws.com/no_manage=true` tag on the TMM data-plane ENI | Applied at the **node/NIC level** (the `high-performance-nodes` module when it lands) and referenced by the **NAD** for TMM (the `network-setup` module) | Required so the AWS VPC CNI (`aws-node`) doesn't try to manage IPs on the same interface TMM uses — otherwise address overlap with TMM's IPAM. |
| GRE tunnels to TGW, F5SPKVlan self-IPs, tmm-init routes | **`bnk-vlans` / `network-setup` modules** when they land | All data-plane network configuration. FLO doesn't know or care about these at install time. |

## Inputs

Auto-wired from upstream modules:

| Input | Source |
|---|---|
| `flo_namespace` | `eks-cluster-install-bnk-prereqs.operator_namespace` |
| `flo_version` | `eks-cluster-install-bnk-prereqs.flo_version` (parsed from the BNK manifest) |
| `far_secret_name` | `eks-cluster-install-bnk-prereqs.far_secret_name` |
| `cluster_issuer_name` | `eks-cluster-install-cert-issuer.cluster_issuer_name` |
| `cluster_name` | `eks-cluster-register.cluster_name` (auto) |
| `cert_manager_ready` | `eks-cluster-install-cert-manager.cert_manager_ready` (gate) |

User-supplied:

| Input | Required | Default |
|---|---|---|
| `jwt_token` | Yes | — (bind to a project secret holding the BNK License JWT) |
| `license_mode` | No | `connected` |
| `f5_license_proxy_url` | No | `""` (only used when `license_mode = f5licenseproxy`) |
| `container_platform` | No | `AWS` |

## Outputs

| Output | Used by |
|---|---|
| `flo_namespace` | `eks-cluster-cneinstall` |
| `flo_ready` | `eks-cluster-cneinstall` (dependency gate) |
| `crds_installed` | `eks-cluster-cneinstall` (dependency gate) |

## Provenance

`values.yaml` and the pack/module metadata were derived from two sources:

1. [`JLCode-tech/bnk-forge-modules/bnk/flo`](https://github.com/JLCode-tech/bnk-forge-modules/tree/release/2.2/bnk/flo) for the cloud-agnostic baseline.
2. The F5 internal *Multinode BNK Deployment in AWS/EKS (FLO)* guide for the AWS-specific value overrides (fluentbit, IPAM operator namespace, image repo overrides, license block).

This module is **not** part of the auto-refresh flow from `bnk-forge-catalog-shared` — `bnk/flo` lives in the legacy module library, and the AWS values are sourced from an internal guide. When a new BNK release ships an updated FLO chart, this module needs a manual review:

1. Diff `oci://repo.f5.com/charts/f5-lifecycle-operator` default values against this `values.yaml` for the new chart version.
2. Re-confirm the AWS-specific overrides against the latest F5 AWS install guidance.
3. Bump `flo_version` defaults (or rely on `bnk-prereqs` parsing it from the new BNK manifest).
4. Test the full chain end-to-end.

## Reference

- [F5 Lifecycle Operator docs](https://clouddocs.f5.com/bigip-next-for-kubernetes/latest/bnk-f5-lifecycle-operator.html)
- [Install BNK via FLO](https://clouddocs.f5.com/bigip-next-for-kubernetes/latest/install/install-using-f5-lifecycle-operator/)
