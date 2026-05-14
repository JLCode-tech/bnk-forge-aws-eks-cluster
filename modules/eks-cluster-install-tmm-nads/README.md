# eks-cluster-install-tmm-nads

Install Multus CNI and the two NetworkAttachmentDefinitions (`ens7-ipvlan-l2` external + `ens8-ipvlan-l2` internal) that TMM data-plane pods bind to. Replaces the manual NAD-apply step the `-with-hp-nodes` blueprints previously required.

## When to use this module

In the four-blueprint matrix, this module is part of both **HP variant** blueprints. It runs after `eks-cluster-hp-nodes` (which attaches `ens7`/`ens8` to HP nodes) and before `eks-cluster-cneinstall` (which references the NAD names in the CNEInstance CR's `networkAttachments` field).

You don't need this module if your blueprint isn't HP-enabled — the non-HP blueprints assume the user has already applied any NADs manually per the F5 install guide and labelled their default-pool nodes for TMM.

## What it does

1. Applies the upstream **Multus daemonset** manifest from `github.com/k8snetworkplumbingwg/multus-cni/<version>/deployments/multus-daemonset.yml`. Default version `v4.1.0`. AWS EKS doesn't ship Multus by default — without it the kubelet rejects pods with `k8s.v1.cni.cncf.io/networks` annotations.
2. Waits for the `network-attachment-definitions.k8s.cni.cncf.io` CRD to be `Established`.
3. Waits for the `kube-multus-ds` DaemonSet to roll out (CNI binary on every node).
4. Applies the **external NAD** (`ens7-ipvlan-l2` by default) — `type: ipvlan, master: ens7, mode: l2`, with a static IPAM placeholder (F5 IPAM operator handles real allocation).
5. Applies the **internal NAD** (`ens8-ipvlan-l2` by default) — same shape but `master: ens8`.

## Inputs

| Name | Default | Description |
|---|---|---|
| `install_multus` | `true` | Set false if your cluster already has Multus from another addon. |
| `multus_version` | `v4.1.0` | Release tag. The full URL is built from this. |
| `multus_manifest_url` | `""` | Override the full URL — useful for air-gapped envs with a private mirror. |
| `nad_namespace` | `default` | Where to create the NADs. F5 reference uses `default`. |
| `nad_external_name` | `ens7-ipvlan-l2` | Must match `cneinstall.network_attachments[0]`. |
| `nad_external_master` | `ens7` | Host interface for the external NAD. Matches `hp-nodes.external_eni_device_index=2 → ens7`. |
| `nad_internal_name` | `ens8-ipvlan-l2` | Must match `cneinstall.network_attachments[1]`. |
| `nad_internal_master` | `ens8` | Matches `hp-nodes.internal_eni_device_index=3 → ens8`. |
| `nad_cni_type` | `ipvlan` | Multus plug-in. On-prem may use `host-device` or `macvlan`. |
| `nad_ipvlan_mode` | `l2` | Only used when `nad_cni_type=ipvlan`. |
| `nad_static_address` | `10.10.1.1/24` | Placeholder ipam address. F5 IPAM operator manages real allocation. |

## Outputs

| Output | Used by |
|---|---|
| `multus_installed` | Diagnostics |
| `nad_external_name`, `nad_internal_name`, `nad_namespace` | Echoed for diagnostics; cneinstall reads its own values from blueprint top-level `network_attachments` |
| `nads_applied` | Gate output — cneinstall depends on this before rendering the CNEInstance CR |

## What it does NOT do

- **Doesn't configure the F5 IPAM operator.** That's handled by FLO's Helm install (which is later in the chain). The placeholder static IP in the NAD just satisfies the Multus + ipvlan CNI schema; TMM gets its actual IP from the F5 IPAM operator.
- **Doesn't install BGP / VLAN CRs.** Those are part of the BNK manifest applied by `bnk-prereqs` and rendered later by FLO.
- **Doesn't manage the kubelet's CNI config.** Multus's daemonset places its config in `/etc/cni/net.d/00-multus.conf` and chains the existing primary CNI underneath — no kubelet restart needed.

## Destroy behaviour

- The two NADs are deleted on `tofu destroy` (`kubectl delete net-attach-def` with `--ignore-not-found`).
- Multus is also deleted (`kubectl delete -f <multus-manifest>`) if this module installed it. If you set `install_multus=false`, the destroy step is skipped.
- The Multus CRD itself stays; deleting it would cascade-delete all NADs cluster-wide, which is too risky.

## Manual override path

If your cluster has Multus from another source (e.g. an AWS EKS addon or a cluster you provisioned with another team's tooling), set `install_multus=false`. The module will then only manage the two NADs.

If you need NADs on a different namespace, set `nad_namespace`. cneinstall reads NAD names not paths — Multus resolves them by name within the pod's namespace, so the CNEInstance namespace and the NAD namespace must match.

## Maturity

`alpha` — same maturity as the HP-nodes module + variant blueprints. Validated together in the next end-to-end test run. Moves to `beta` after first successful live deploy, `1.0.0` alongside the rest of the catalog after full validation.
