# install-multus

Cloud-agnostic primitive: install Multus CNI on a Kubernetes cluster.

## What this module does

[Multus](https://github.com/k8snetworkplumbingwg/multus-cni) is a meta-CNI that lets pods attach to multiple networks. One CNI manages the primary pod interface (the cluster's default — e.g. AWS VPC CNI, Azure CNI, Calico on-prem); Multus chains additional interfaces via `NetworkAttachmentDefinition` CRs.

BNK's TMM data-plane model needs Multus whenever TMM pods carry secondary host interfaces (the generic 3-interface TMM model: CNI + external + internal). AWS EKS, Azure AKS, and GCP GKE do **not** ship Multus by default; on-prem clusters may or may not.

This module installs Multus and **only** Multus. It deliberately knows nothing about cloud APIs, host interface names, or NAD specifics — those belong in a per-cloud follow-up module (e.g. `eks-cluster-install-tmm-nads` on AWS).

## How it installs

1. `kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/<version>/deployments/multus-daemonset.yml` (default version `v4.2.4`, URL overridable for air-gapped envs).
2. `kubectl wait --for=condition=Established crd/network-attachment-definitions.k8s.cni.cncf.io` — ensures the CRD is ready before any downstream module tries to create NAD resources.
3. `kubectl rollout status ds/kube-multus-ds -n kube-system` — ensures the CNI binary is on every node before any pod needing secondary networks schedules.

## When to chain something after this

The intended pattern in a per-cloud catalog:

```
install-multus       (this module — cloud-agnostic)
    └─→ install-<cloud>-nads  (per-cloud — creates the NAD resources Multus chains in)
            └─→ cneinstall    (BNK control plane — references the NAD names)
```

Downstream NAD modules should set their `depends_on` against `install-multus.multus_ready`.

## Inputs

| Name | Default | Description |
|---|---|---|
| `install_multus` | `true` | Set false if your cluster already has Multus from another source. |
| `multus_version` | `v4.2.4` | Release tag — URL is built from this. |
| `multus_manifest_url` | `""` | Explicit override URL for air-gapped / mirrored envs. |
| `multus_crd_wait_timeout` | `120s` | `kubectl wait` timeout for the CRD to become `Established`. |
| `multus_rollout_wait_timeout` | `180s` | `kubectl rollout status` timeout for the DaemonSet. |

## Outputs

| Output | Used by |
|---|---|
| `multus_installed` | Diagnostics |
| `multus_manifest_url` | Diagnostics — exactly which URL was applied |
| `multus_ready` | **Gate output** — downstream NAD modules depend on this |

## Destroy behaviour

`kubectl delete -f <manifest-url>` with `--ignore-not-found`. The CRD itself is left in place (deleting it would cascade-delete every NAD cluster-wide — too risky).

## When NOT to use this module

- Your cluster's primary CNI is already Multus-aware (some on-prem distributions integrate it directly). Set `install_multus=false` or skip this module entirely.
- You're not using BNK TMM secondary networks (single-interface TMM, or you're on a path that doesn't need data-plane separation). Multus is overhead in that case.

## Vendoring into per-cloud catalogs

This module is consumed by per-cloud catalogs via `scripts/vendor-refresh.sh` at a pinned tag, then renamed on the way in. AWS catalog imports it as `modules/eks-cluster-install-multus`.

## Maturity

`alpha` — extracted from the AWS-specific `eks-cluster-install-tmm-nads` module's Multus install logic. The logic itself has been in the AWS catalog through several iterations; this version is the cloud-agnostic split.
