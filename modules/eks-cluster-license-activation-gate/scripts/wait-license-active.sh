#!/usr/bin/env bash
#
# wait-license-active.sh
#
# Apply-then-gate for the BNK License CR. Ported from awsbnkctl
# internal/aws/phases/phase23_license.go (CRD pre-gate + server-side apply) and
# phase25_activation_poll.go (the .status.state == "Active" gate, 30s+18x30s
# timing, dumpPodDiagnostics).
#
# Three steps, in order:
#   1. CRD pre-gate: kubectl get crd <license_crd_name> must exist within
#      CRD_TIMEOUT seconds. FLO installs this CRD; the operator cannot reconcile
#      a License whose CRD is not registered.
#   2. Apply: render the License CR (the manifest arrives via LICENSE_MANIFEST
#      with a __JWT__ placeholder; the raw JWT arrives separately via LICENSE_JWT)
#      and `kubectl apply --server-side` it. Idempotent: SSA on an already-Active
#      License does not flip it.
#   3. Activation gate: poll
#        kubectl get license <name> -n <ns> -o jsonpath={.status.state}
#      until == "Active". Any other value (empty, NotActivated, Failed, ...) =
#      keep polling, up to ACTIVATION_TIMEOUT.
#
# On activation-gate timeout the script dumps per-pod diagnostics for the
# license namespace (phase/reason + recent events for non-Running pods) and
# exits 1 so Terraform fails the apply (fail closed). The last-seen state is
# printed in the error.
#
# JWT SAFETY: the JWT is never echoed. The shell runs without `set -x`; the
# JWT substitution + manifest write happen inside an explicit `set +x` guard
# and the rendered manifest is a 0600 temp file deleted on EXIT. The manifest
# is applied via `kubectl apply -f <file>` (not piped on the command line) so
# the token never appears in `ps`/argv.
#
# All kubectl invocations go through $KUBECTL (defaults to "kubectl"), which
# the unit tests override to a mock stub on PATH.

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"

LICENSE_NAMESPACE="${LICENSE_NAMESPACE:?LICENSE_NAMESPACE is required}"
LICENSE_NAME="${LICENSE_NAME:?LICENSE_NAME is required}"
LICENSE_CRD_NAME="${LICENSE_CRD_NAME:-licenses.k8s.f5net.com}"
LICENSE_MANIFEST="${LICENSE_MANIFEST:?LICENSE_MANIFEST is required (rendered License CR with __JWT__ placeholder)}"
LICENSE_JWT="${LICENSE_JWT:?LICENSE_JWT is required (raw JWT)}"
FIELD_MANAGER="${FIELD_MANAGER:-bnk-forge}"
ACTIVATION_TIMEOUT="${ACTIVATION_TIMEOUT:-570}"
CRD_TIMEOUT="${CRD_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
CRD_POLL_INTERVAL="${CRD_POLL_INTERVAL:-5}"

log() { echo "[license-gate] $*" >&2; }

# Temp manifest with the real JWT. 0600, deleted on exit.
MANIFEST_FILE=""
cleanup() {
  if [ -n "$MANIFEST_FILE" ]; then
    rm -f "$MANIFEST_FILE"
  fi
}
trap cleanup EXIT

# --- Gate 1: CRD pre-gate ----------------------------------------------------
wait_for_crd() {
  log "waiting for CRD ${LICENSE_CRD_NAME} (max ${CRD_TIMEOUT}s)"
  local elapsed=0
  while [ "$elapsed" -lt "$CRD_TIMEOUT" ]; do
    if $KUBECTL get crd "$LICENSE_CRD_NAME" >/dev/null 2>&1; then
      log "CRD ${LICENSE_CRD_NAME} present after ${elapsed}s"
      return 0
    fi
    sleep "$CRD_POLL_INTERVAL"
    elapsed=$((elapsed + CRD_POLL_INTERVAL))
  done
  log "ERROR: CRD ${LICENSE_CRD_NAME} not registered after ${CRD_TIMEOUT}s"
  return 1
}

# --- Step 2: render + server-side apply the License CR -----------------------
# JWT handling is isolated here. No `set -x` is in effect; we make the +x guard
# explicit and never echo the token or the rendered file.
apply_license() {
  set +x
  MANIFEST_FILE="$(mktemp)"
  chmod 0600 "$MANIFEST_FILE"
  # Substitute the placeholder with the raw JWT. Use bash string replacement so
  # the token never reaches a sed program text or argv. Written straight to the
  # 0600 temp file.
  printf '%s\n' "${LICENSE_MANIFEST//__JWT__/$LICENSE_JWT}" > "$MANIFEST_FILE"

  log "applying License ${LICENSE_NAMESPACE}/${LICENSE_NAME} (server-side, field-manager=${FIELD_MANAGER})"
  if ! $KUBECTL apply --server-side --force-conflicts \
      --field-manager "$FIELD_MANAGER" -f "$MANIFEST_FILE" >&2; then
    log "ERROR: kubectl apply of License ${LICENSE_NAMESPACE}/${LICENSE_NAME} failed"
    return 1
  fi
  # Drop the JWT-bearing file as soon as it is applied.
  rm -f "$MANIFEST_FILE"
  MANIFEST_FILE=""
  return 0
}

# --- License state read (mirror phase25 licState) ----------------------------
current_state() {
  $KUBECTL -n "$LICENSE_NAMESPACE" get license "$LICENSE_NAME" \
    -o "jsonpath={.status.state}" 2>/dev/null || true
}

license_active() {
  [ "$(current_state)" = "Active" ]
}

# --- Diagnostics (mirror phase25 dumpPodDiagnostics) -------------------------
dump_pod_diagnostics() {
  log "FAIL diag: dumping pod state in namespace ${LICENSE_NAMESPACE}"
  local pods
  pods="$($KUBECTL -n "$LICENSE_NAMESPACE" get pods \
    -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.status.reason}{"|"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' \
    2>/dev/null || true)"
  if [ -z "$pods" ]; then
    log "FAIL diag: no pods found (or kubectl error) in ${LICENSE_NAMESPACE}"
    return 0
  fi
  while IFS='|' read -r name phase reason waiting_reason; do
    [ -z "$name" ] && continue
    [ -z "$reason" ] && reason="$waiting_reason"
    log "FAIL diag: pod=${name} phase=${phase} reason=${reason}"
    [ "$phase" = "Running" ] && continue
    local events
    events="$($KUBECTL -n "$LICENSE_NAMESPACE" get events \
      --field-selector "involvedObject.name=${name}" \
      -o 'jsonpath={range .items[*]}{.reason}{" "}{.message}{"\n"}{end}' \
      2>/dev/null || true)"
    if [ -n "$events" ]; then
      while IFS= read -r ev; do
        [ -z "$ev" ] && continue
        log "FAIL diag:   event: ${ev}"
      done <<EOF
$(echo "$events" | tail -n 10)
EOF
    fi
  done <<EOF
$pods
EOF
}

# --- Step 3: activation poll loop --------------------------------------------
wait_for_active() {
  log "polling License ${LICENSE_NAMESPACE}/${LICENSE_NAME} for activation (max ${ACTIVATION_TIMEOUT}s, interval ${POLL_INTERVAL}s)"
  local elapsed=0
  while :; do
    if license_active; then
      log "License ${LICENSE_NAMESPACE}/${LICENSE_NAME} is Active"
      return 0
    fi
    if [ "$elapsed" -ge "$ACTIVATION_TIMEOUT" ]; then
      break
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    log "[${elapsed}/${ACTIVATION_TIMEOUT}s] not active yet (state=$(current_state))"
  done
  log "ERROR: timeout after ${ACTIVATION_TIMEOUT}s — License ${LICENSE_NAMESPACE}/${LICENSE_NAME} last state=$(current_state)"
  dump_pod_diagnostics
  return 1
}

main() {
  wait_for_crd || exit 1
  apply_license || exit 1
  wait_for_active || exit 1
  log "License ${LICENSE_NAMESPACE}/${LICENSE_NAME} activated"
}

main "$@"
