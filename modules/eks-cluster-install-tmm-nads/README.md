# eks-cluster-install-tmm-nads

Creates the two AWS-specific NetworkAttachmentDefinitions (`ens7-ipvlan-l2` external + `ens8-ipvlan-l2` internal) that TMM data-plane pods bind to, with apply-time tag discovery to derive each NAD's static IPAM placeholder from the actual TMM subnet CIDRs.

> **Multus install is now a separate step** — handled by `eks-cluster-install-multus` (vendored from `bnk-forge-catalog-shared`). This module depends on Multus being up via the `multus_ready` gate. The split keeps the cloud-agnostic Multus install logic reusable across catalogs (Azure, GCP, on-prem) while AWS-specific NAD plumbing stays here.

## When to use this module

In the four-blueprint matrix, this module is part of both **HP variant** blueprints. It runs after `eks-cluster-hp-nodes` (which attaches `ens7`/`ens8` to HP nodes) and before `eks-cluster-cneinstall` (which references the NAD names in the CNEInstance CR's `networkAttachments` field).

You don't need this module if your blueprint isn't HP-enabled — the non-HP blueprints assume the user has already applied any NADs manually per the F5 install guide and labelled their default-pool nodes for TMM.

## What it does

1. **Discovers** `f5-bnk-role=tmm-external` and `f5-bnk-role=tmm-internal` subnets in the cluster VPC (same query `cneinstall` runs) and derives each NAD's static IPAM placeholder from the matching subnet's CIDR.
2. Asserts `var.multus_ready == true` via a `lifecycle.precondition` — fails loudly if Multus wasn't installed first (blueprint wiring error).
3. Applies the **external NAD** (`ens7-ipvlan-l2` by default) — `type: ipvlan, master: ens7, mode: l2`, static placeholder = `cidrhost(<tmm-external CIDR>, 1)/<prefix>`.
4. Applies the **internal NAD** (`ens8-ipvlan-l2` by default) — same shape but `master: ens8`, placeholder from the tmm-internal subnet.

The CNI `static` IPAM type requires at least one address. TMM doesn't actually use the placeholder for traffic — the F5 IPAM operator handles real allocation at runtime — but keeping it inside the actual subnet the ENI lives on means the NAD is internally consistent and there's no surprise when an operator inspects the config.

## Upstream gate

`var.multus_ready` is set by `eks-cluster-install-multus`'s `multus_ready` output, auto-wired via the pack manifest. The variant blueprints chain:

```
hp-nodes → install-multus → tmm-nads → ... → cneinstall
```

If you wire this module without `install-multus` ahead of it, the `lifecycle.precondition` fails at plan time with a clear error.

## Inputs

| Name | Source | Default | Description |
|---|---|---|---|
| `aws_*` creds | AWS credential template | — | Any of Forge's three auth methods. Required for the tag-discovery query. |
| `aws_region` | User / project | — | Region for the data sources. |
| `vpc_id` | Upstream module | — | Auto-wired from cluster-register / cluster-create. Scopes the discovery. |
| `multus_ready` | Upstream module | `false` | Auto-wired from `install-multus.multus_ready`. Module precondition fails at plan if this is false. |
| `nad_namespace` | User | `default` | Where to create the NADs. F5 reference uses `default`. |
| `nad_external_name` | User | `ens7-ipvlan-l2` | Must match `cneinstall.network_attachments[0]`. |
| `nad_external_master` | User | `ens7` | Host interface for the external NAD. Matches `hp-nodes.external_eni_device_index=2 → ens7`. |
| `nad_internal_name` | User | `ens8-ipvlan-l2` | Must match `cneinstall.network_attachments[1]`. |
| `nad_internal_master` | User | `ens8` | Matches `hp-nodes.internal_eni_device_index=3 → ens8`. |
| `nad_cni_type` | User | `ipvlan` | Multus plug-in. On-prem may use `host-device` or `macvlan`. |
| `nad_ipvlan_mode` | User | `l2` | Only used when `nad_cni_type=ipvlan`. |
| `nad_external_static_address` | User | `""` → derive | Override the derived external placeholder. Set explicitly to bypass discovery. |
| `nad_internal_static_address` | User | `""` → derive | Override the derived internal placeholder. |
| `nad_static_address_fallback` | User | `10.10.1.1/24` | Used only when discovery returns no tagged subnets AND no per-NAD override is set. |

### Static-address resolution order (per NAD)

1. **Explicit override** (`nad_external_static_address` / `nad_internal_static_address`) — used verbatim if set.
2. **Tag discovery** — `cidrhost(<first f5-bnk-role-tagged subnet CIDR>, 1)/<matching prefix>`. Subnet CIDRs are sorted for determinism; index `[0]` is picked.
3. **Fallback** (`nad_static_address_fallback`, default `10.10.1.1/24`) — kicks in only when both (1) and (2) yield nothing.

## Outputs

| Output | Used by |
|---|---|
| `nad_external_name`, `nad_internal_name`, `nad_namespace` | Echoed for diagnostics; cneinstall reads its own values from blueprint top-level `network_attachments` |
| `nad_external_static_address`, `nad_internal_static_address` | Resolved placeholders (override / derived / fallback). Useful in plan logs to confirm derivation picked the right subnet. |
| `discovered_tmm_external_cidrs`, `discovered_tmm_internal_cidrs` | Subnet CIDRs the module discovered via the f5-bnk-role tags |
| `nads_applied` | Gate output — cneinstall depends on this before rendering the CNEInstance CR |

## What it does NOT do

- **Doesn't configure the F5 IPAM operator.** That's handled by FLO's Helm install (which is later in the chain). The placeholder static IP in the NAD just satisfies the Multus + ipvlan CNI schema; TMM gets its actual IP from the F5 IPAM operator.
- **Doesn't install BGP / VLAN CRs.** Those are part of the BNK manifest applied by `bnk-prereqs` and rendered later by FLO.
- **Doesn't manage the kubelet's CNI config.** Multus's daemonset places its config in `/etc/cni/net.d/00-multus.conf` and chains the existing primary CNI underneath — no kubelet restart needed.

## Destroy behaviour

- The two NADs are deleted on `tofu destroy` (`kubectl delete net-attach-def` with `--ignore-not-found`).
- Multus itself is removed by `install-multus`'s destroy provisioner (handled by the upstream module, not here).

## Manual override path

If you need NADs in a different namespace, set `nad_namespace`. cneinstall reads NAD names not paths — Multus resolves them by name within the pod's namespace, so the CNEInstance namespace and the NAD namespace must match.

## Maturity

`alpha` — same maturity as the HP-nodes module + variant blueprints. Validated together in the next end-to-end test run. Moves to `beta` after first successful live deploy, `1.0.0` alongside the rest of the catalog after full validation.
