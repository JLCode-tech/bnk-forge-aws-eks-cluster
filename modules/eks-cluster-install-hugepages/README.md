# install-hugepages

Cloud-agnostic primitive: apply a hugepages-setup DaemonSet on BNK worker nodes.

## What this module does

F5 TMM requires `hugepages-2Mi` capacity on every node it runs on. Without it, the TMM pod fails to schedule with `Insufficient hugepages-2Mi`.

This module applies a privileged DaemonSet (`hugepages-setup` in `kube-system`) that:

1. Runs on all nodes labelled `role=bnk` (the label your cluster admin applies to TMM-designated nodes — see [F5 docs on node labels](https://clouddocs.f5.com/bigip-next-for-kubernetes/2.0.0-LA/node-label.html)).
2. Sets `vm.nr_hugepages=2048` (2048 × 2 Mi = 4 GB of 2 Mi hugepages) via the `/sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages` sysfs path.
3. Zeroes any pre-existing 1 Gi hugepages (TMM only consumes 2 Mi hugepages).
4. Restarts `kubelet` via `nsenter` so the capacity surfaces in `.status.capacity.hugepages-2Mi` before downstream phases schedule TMM.

After the DaemonSet rolls out on all `role=bnk` nodes, this module's gate output (`hugepages_ready`) fires.

## Source reference

Manifest: `awsbnkctl:internal/k8s/manifests/shared/hugepages-ds.yaml`
Apply + wait logic: `awsbnkctl:internal/aws/phases/phase11b_ebs_csi_hugepages.go` (Phase 11b.2 and 11b.3)

The manifest is bundled locally in `manifests/hugepages-ds.yaml` (not fetched at apply time) so air-gapped environments and vendored copies work without internet access.

## When to chain this

```
install-multus           (cloud-agnostic)
    └─→ install-hugepages       (this module — cloud-agnostic)
            └─→ cneinstall       (BNK control plane — needs hugepages on node)
                    └─→ cneinstance → install-spkvlan-gatewayclass
```

The per-cloud wrapper (`eks-cluster-install-hugepages` in `bnk-forge-catalog-aws-eks`) may add an additional per-node kubelet capacity gate (matching awsbnkctl Phase 11b.3) via a `data.external` script if needed.

## Inputs

| Name | Default | Description |
|---|---|---|
| `install_hugepages` | `true` | Set false if hugepages are already configured on the cluster's BNK nodes. |
| `daemonset_rollout_timeout` | `300s` | `kubectl rollout status` timeout. Default matches awsbnkctl Phase 11b `hugepagesReadyTimeout = 5 min`. |

## Outputs

| Output | Used by |
|---|---|
| `hugepages_installed` | Diagnostics |
| `hugepages_ready` | **Gate output** — downstream `cneinstall` depends on this |

## Destroy behaviour

`kubectl delete -f manifests/hugepages-ds.yaml --ignore-not-found`. The sysfs hugepages setting persists until node reboot (DaemonSet deletion does not undo the kernel setting). For full cleanup, drain and recycle the node.

## Node label prerequisite

The DaemonSet `nodeSelector` is `role: bnk`. The cluster administrator must label each TMM-designated node with `kubectl label node <node-name> role=bnk` before this module runs. See [F5 node-label docs](https://clouddocs.f5.com/bigip-next-for-kubernetes/2.0.0-LA/node-label.html).

## Vendoring into per-cloud catalogs

Per-cloud catalogs vendor this as (e.g.) `modules/eks-cluster-install-hugepages` via `scripts/vendor-refresh.sh`. The AWS wrapper may add an additional capacity-wait step (awsbnkctl Phase 11b.3) that polls `.status.capacity.hugepages-2Mi` on the TMM node via a `data.external` script.

## Maturity

`alpha` — extracted from awsbnkctl Phase 11b; logic is proven in production EKS deploys.
