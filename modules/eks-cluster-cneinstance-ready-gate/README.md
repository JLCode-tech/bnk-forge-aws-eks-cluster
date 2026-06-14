# cneinstance-ready-gate

Cloud-agnostic readiness gate for a BNK CNEInstance.

## What this module does

After a `CNEInstance` CR is applied, FLO + the CNE controller roll out the BNK
runtime (CWC, DSSM, Observer, OTEL, RabbitMQ, TMM, IPAM) asynchronously. A
deploy must **not** declare success until the operator's own `.status` says the
instance is functional — otherwise it reports "ready" against a cluster that is
not licensed and cannot pass traffic (the "HTTP 200 ≠ operation success" class
of bug, baked into the blueprint).

This module runs `scripts/wait-cneinstance-ready.sh`, which:

1. **CRD pre-gate** — waits up to `crd_timeout_seconds` for
   `kubectl get crd <cne_crd_name>` to exist. The operator can't reconcile a
   CNEInstance whose CRD isn't registered.
2. **Condition gate** — polls the named CNEInstance every
   `poll_interval_seconds` (up to `condition_timeout_seconds`) until **both**

   ```
   status.conditions[type=F5TmmAvailable].status        == "True"   AND
   status.conditions[type=CNEControllerAvailable].status == "True"
   ```

   **or** (back-compat for older FLO/BNK 2.2) `status.state ∈ {Ready, Running}`.
3. **Fail closed** — on timeout it dumps per-pod diagnostics (phase/reason +
   recent events for non-Running pods) for the instance namespace and `exit 1`
   so Terraform fails the apply.

The logic is ported from `awsbnkctl internal/aws/phases/phase25_activation_poll.go`
(`cneFunctionallyReady` / `isCNEReady` / `dumpPodDiagnostics`).

### Why not the rollup `Available` condition (H1)

We deliberately do **not** gate on the CNEInstance's rollup `Available`
condition. Healthy production clusters run for weeks with `Available=False`
because DSSM HA replicas (`f5-dssm-db-1`) are Pending and are **not** on the BNK
data path — the rollup aggregates them anyway. The two sub-conditions above are
what actually mean "traffic can flow". See the awsbnkctl phase25 H1 comment and
`docs/audits/2026-05-24-live-e2e-round-2-findings.md`.

## Inputs

| Name | Default | Description |
|---|---|---|
| `instance_namespace` | _(required)_ | Namespace of the CNEInstance CR. On forge EKS this is `operator_namespace` (default `f5-operator`) — **not** awsbnkctl's `f5-cne-system`. |
| `instance_name` | _(required)_ | Name of the CNEInstance CR to poll. |
| `kubeconfig_file` | `""` | Path to an existing kubeconfig. Pass the wrapper's `local_sensitive_file.kubeconfig.filename`. Empty = materialise from `forge_kubeconfig_content`. |
| `cne_crd_name` | `cneinstances.k8s.f5.com` | CRD name for the pre-gate. |
| `condition_timeout_seconds` | `570` | Readiness-condition timeout (~9.5 min). |
| `crd_timeout_seconds` | `300` | CRD pre-gate timeout. |
| `poll_interval_seconds` | `30` | Seconds between condition polls. |

## Outputs

| Output | Description |
|---|---|
| `cneinstance_ready` | **Gate output** — the readiness `null_resource` id, produced only after the gate exited 0. Never a literal `true`. If the gate times out, the apply fails and this is never produced. Downstream steps (License, traffic checks) depend on it. |
| `instance_namespace` / `instance_name` | Echo of the gated instance identity. |

## Usage

```hcl
module "ready_gate" {
  source             = "../cneinstance-ready-gate" # or the vendored copy
  kubeconfig_file    = local_sensitive_file.kubeconfig.filename
  instance_namespace = var.operator_namespace
  instance_name      = var.instance_name

  depends_on = [null_resource.cneinstance]
}

output "cneinstance_ready" {
  value = module.ready_gate.cneinstance_ready
}
```

## Adding a License check later (P2)

The gate is structured so a `License.status.state == "Active"` check can be
added as an optional, toggled-off input later without changing the contract —
mirror awsbnkctl phase25's combined `cneReady && licState == "Active"` success.
Out of scope for P1.

## Testing

`tests/run-tests.sh` drives the poll script against a mock `kubectl` stub (no
cluster, no AWS). See that directory's header for cases and the run command.

## Vendoring into per-cloud catalogs

A CNEInstance CR + operator conditions are identical on every cloud, so this
module is cloud-agnostic and is consumed by per-cloud catalogs via
`scripts/vendor-refresh.sh` at a pinned ref, then renamed on the way in. The AWS
catalog imports it as `modules/eks-cluster-cneinstance-ready-gate`. AKS/GKE
adopt it with the same two-line vendor mapping plus one `module "ready_gate"`
block after their cneinstall step.

## Maturity

`alpha` — ported from the awsbnkctl phase-25 activation poll, which has run
against live clusters (aws-syd-test) through several iterations.
