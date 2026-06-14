# license-activation-gate

Cloud-agnostic apply-then-gate for the BNK `License` CR.

## What this module does

FLO's Helm `license.*` values configure the license controller and the TEEM
verification material — they do **not** materialise a `License` CR. Nothing in
the forge per-cloud catalogs applies one either. So a forge BNK deploy hands the
JWT to FLO but never creates a `License` object and never verifies that the
operator activated it: the classic "HTTP 200 ≠ operation success" bug (D-017),
baked into the blueprint.

`awsbnkctl` (the gold standard) applies the CR itself (`phase23_license.go`,
server-side apply after the CRD registers) and then gates on
`.status.state == "Active"` (`phase25_activation_poll.go`). This module ports
that apply-then-gate contract.

It runs `scripts/wait-license-active.sh`, which:

1. **CRD pre-gate** — waits up to `crd_timeout_seconds` for
   `kubectl get crd <license_crd_name>` to exist. FLO installs the CRD; the
   operator can't reconcile a `License` whose CRD isn't registered.
2. **Server-side apply** — renders the `License` CR and
   `kubectl apply --server-side --force-conflicts --field-manager bnk-forge`s
   it into `license_namespace`. **Idempotent** — SSA on an already-Active
   license does not flip it.
3. **Activation gate** — polls
   `kubectl get license <name> -n <ns> -o jsonpath={.status.state}` every
   `poll_interval_seconds` (up to `activation_timeout_seconds`). Only `Active`
   is success; empty / `NotActivated` / `Failed` / anything else keeps polling.
4. **Fail closed** — on timeout it dumps per-pod diagnostics (phase/reason +
   recent events for non-Running pods) for the license namespace and `exit 1`
   so Terraform fails the apply.

### The License CR applied

```yaml
apiVersion: k8s.f5net.com/v1
kind: License
metadata:
  name: bnk-license          # license_name
  namespace: f5-operator     # license_namespace (= operator_namespace), NOT awsbnkctl's f5-cne-core
  labels:
    app.kubernetes.io/name: bnk-license
    app.kubernetes.io/managed-by: bnk-forge
    app.kubernetes.io/instance: bnk-license
spec:
  operationMode: connected   # operation_mode
  jwt: <raw JWT>             # jwt_token, inlined (no base64 / secretRef)
  teemCertUrl: https://product.apis.f5.com/ee/v1
  teemEntitlementUrl: https://product-s.apis.f5.com/ee/v1
  teemInitialConfigUrl: https://product-s.apis.f5.com/ee/v1
```

### JWT safety

The JWT is **never** logged or interpolated into Terraform state. `main.tf`
renders the CR via `templatefile()` with a `__JWT__` placeholder (so the stored
string carries no secret), and passes the raw JWT to the script in a separate
env var. The script substitutes the placeholder into a `0600` temp file inside
an explicit `set +x` guard, applies it with `kubectl apply -f <file>` (so the
token never reaches `ps`/argv), and deletes the file immediately after apply
(and again on `EXIT`).

## Inputs

| Name | Default | Description |
|---|---|---|
| `license_namespace` | _(required)_ | Namespace the License CR is applied into. On forge EKS this is `operator_namespace` (default `f5-operator`) — **not** awsbnkctl's `f5-cne-core`. |
| `jwt_token` | _(required, sensitive)_ | Raw F5 BNK JWT. Inlined into `spec.jwt`. Same secret FLO takes. |
| `kubeconfig_file` | `""` | Path to an existing kubeconfig. Pass the wrapper's `local_sensitive_file.kubeconfig.filename`. Empty = materialise from `forge_kubeconfig_content`. |
| `license_name` | `bnk-license` | Name of the License CR. |
| `operation_mode` | `connected` | License `operationMode`. Connected only. |
| `license_crd_name` | `licenses.k8s.f5net.com` | CRD name for the pre-gate. |
| `teem_cert_url` | `https://product.apis.f5.com/ee/v1` | `spec.teemCertUrl`. |
| `teem_entitlement_url` | `https://product-s.apis.f5.com/ee/v1` | `spec.teemEntitlementUrl`. |
| `teem_initial_config_url` | `https://product-s.apis.f5.com/ee/v1` | `spec.teemInitialConfigUrl`. |
| `activation_timeout_seconds` | `570` | Activation-gate timeout (~9.5 min). |
| `crd_timeout_seconds` | `300` | CRD pre-gate timeout. |
| `poll_interval_seconds` | `30` | Seconds between activation polls. |

## Outputs

| Output | Description |
|---|---|
| `license_active` | **Gate output** — the activation `null_resource` id, produced only after the gate exited 0 (operator reported `.status.state == Active`). Never a literal `true`. If the gate times out, the apply fails and this is never produced. |
| `license_namespace` / `license_name` | Echo of the applied License identity. |

## Usage

```hcl
module "license_activation_gate" {
  source            = "../license-activation-gate" # or the vendored copy
  kubeconfig_file   = local_sensitive_file.kubeconfig.filename
  license_namespace = var.operator_namespace
  jwt_token         = var.jwt_token

  depends_on = [module.ready_gate] # chain AFTER the CNEInstance readiness gate
}

output "license_active" {
  value = module.license_activation_gate.license_active
}
```

## Testing

`tests/run-tests.sh` drives the apply-then-gate script against a mock `kubectl`
stub (no cluster, no AWS). It proves: applies the CR then passes on `Active`;
timeout fail-with-diagnostics; no-pass on empty/`NotActivated`/`Failed`;
CRD-missing fail-closed; apply-failure fail-closed; and that a `kubectl apply`
of a `kind: License` was issued with the JWT in the manifest file but **never**
on argv.

```
bash modules/license-activation-gate/tests/run-tests.sh
```

## Vendoring into per-cloud catalogs

A `License` CR + operator `.status` are identical on every cloud, so this module
is cloud-agnostic and is consumed by per-cloud catalogs via
`scripts/vendor-refresh.sh` at a pinned ref, then renamed on the way in. The AWS
catalog imports it as `modules/eks-cluster-license-activation-gate`. AKS/GKE
adopt it with the same two-line vendor mapping plus one `module
"license_activation_gate"` block after their cneinstance readiness gate.

## Maturity

`alpha` — ported from the awsbnkctl phase-23/phase-25 license apply + activation
poll, which has run against live clusters (aws-syd-test) through several
iterations.
