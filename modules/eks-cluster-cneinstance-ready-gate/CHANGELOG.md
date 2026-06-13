# Changelog

All notable changes to this module will be documented in this file.

## [0.1.0-alpha] - 2026-06-13

### Added
- Initial release. Cloud-agnostic CNEInstance readiness gate.
- CRD pre-gate + condition poll loop in `scripts/wait-cneinstance-ready.sh`,
  ported from `awsbnkctl internal/aws/phases/phase25_activation_poll.go`:
  - `F5TmmAvailable == True AND CNEControllerAvailable == True`
  - back-compat fallback `status.state ∈ {Ready, Running}`
  - **does NOT** gate on the rollup `Available` condition (H1).
- Fail-closed pod diagnostics dump on timeout (`dumpPodDiagnostics` port).
- `cneinstance_ready` output derived from the gating `null_resource` id (not a
  literal `true`).
- `tests/run-tests.sh` — mock-`kubectl` unit harness covering both-True pass,
  state-fallback pass, timeout fail-with-diagnostics, single-condition no-pass,
  and the `Available`-rollup-ignored case. No cluster / no AWS required.

### Notes
- Designed so a P2 `License.status.state == "Active"` check can be added as an
  optional toggled-off input later without changing the contract.
