# Changelog

All notable changes to this module will be documented in this file.

## [0.1.0-alpha] - 2026-06-13

### Added
- Initial release. Cloud-agnostic apply-then-gate for the BNK License CR.
- `scripts/wait-license-active.sh`, ported from
  `awsbnkctl internal/aws/phases/phase23_license.go` (CRD pre-gate + server-side
  apply) and `phase25_activation_poll.go` (the `.status.state == "Active"`
  gate + `dumpPodDiagnostics`):
  - CRD pre-gate for `licenses.k8s.f5net.com` (FLO installs it).
  - Server-side apply (`--server-side --force-conflicts --field-manager bnk-forge`)
    of the rendered License CR. Idempotent — SSA on an already-Active license
    does not flip it.
  - Activation poll: only `.status.state == "Active"` is success; empty /
    `NotActivated` / `Failed` keep polling up to `activation_timeout_seconds`.
  - Fail-closed pod diagnostics dump + `exit 1` on timeout.
- `manifests/license.yaml.tftpl` — reviewable License CR rendered by
  `templatefile()` with a `__JWT__` placeholder; the raw JWT is substituted into
  a `0600` temp file at apply time so it never enters Terraform state or logs and
  never appears on `kubectl` argv.
- `license_active` output derived from the gating `null_resource` id (not a
  literal `true`).
- `tests/run-tests.sh` — mock-`kubectl` unit harness covering: applies then
  passes on `Active`; timeout-fail-with-diagnostics; no-pass on
  empty/`NotActivated`/`Failed`; CRD-missing fail-closed; apply-failure
  fail-closed; and proof that a `kubectl apply` of a `kind: License` was issued
  with the JWT in the manifest file but NEVER on argv. No cluster / no AWS.

### Notes
- Connected (TEEM online) licensing only. Disconnected / air-gapped
  (`f5licenseproxy`) is out of scope.
- Namespace defaults to the forge operator namespace (`f5-operator`), NOT
  awsbnkctl's `f5-cne-core`.
- Designed to chain AFTER `cneinstance-ready-gate` (P1): apply + activate the
  license only once the CNEInstance is functionally ready.
