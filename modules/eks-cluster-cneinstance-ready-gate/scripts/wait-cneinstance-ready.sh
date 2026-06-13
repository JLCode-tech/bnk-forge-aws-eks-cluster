#!/usr/bin/env bash
#
# wait-cneinstance-ready.sh
#
# Honest readiness gate for a BNK CNEInstance. Ported from awsbnkctl
# internal/aws/phases/phase25_activation_poll.go (the gate, the F5TmmAvailable +
# CNEControllerAvailable sub-conditions, the state-fallback, the H1 "do not use
# rollup Available" decision, and dumpPodDiagnostics).
#
# Two gates, in order:
#   1. CRD pre-gate: kubectl get crd <cne_crd_name> must exist within
#      CRD_TIMEOUT seconds. The operator cannot reconcile a CNEInstance whose
#      CRD is not registered.
#   2. Condition gate: the named CNEInstance is functionally ready when BOTH
#        status.conditions[type=F5TmmAvailable].status   == "True"  AND
#        status.conditions[type=CNEControllerAvailable].status == "True"
#      OR (back-compat fallback for older FLO/BNK 2.2)
#        status.state ∈ {"Ready","Running"}.
#      Polled every POLL_INTERVAL seconds up to CONDITION_TIMEOUT.
#
# H1 — we deliberately do NOT gate on the rollup `Available` condition: healthy
# clusters run for weeks with Available=False because DSSM HA replicas
# (f5-dssm-db-1) are Pending and are NOT on the data path. The sub-conditions
# above are what actually mean "traffic can flow". See awsbnkctl phase25 lines
# 85-93 and docs/audits/2026-05-24-live-e2e-round-2-findings.md (H1).
#
# On condition-gate timeout the script dumps per-pod diagnostics for the
# instance namespace (phase/reason + recent events for non-Running pods) and
# exits 1 so Terraform fails the apply (fail closed).
#
# All kubectl invocations go through $KUBECTL (defaults to "kubectl"), which
# the unit tests override to a mock stub on PATH.

set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"

INSTANCE_NAMESPACE="${INSTANCE_NAMESPACE:?INSTANCE_NAMESPACE is required}"
INSTANCE_NAME="${INSTANCE_NAME:?INSTANCE_NAME is required}"
CNE_CRD_NAME="${CNE_CRD_NAME:-cneinstances.k8s.f5.com}"
CONDITION_TIMEOUT="${CONDITION_TIMEOUT:-570}"
CRD_TIMEOUT="${CRD_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
CRD_POLL_INTERVAL="${CRD_POLL_INTERVAL:-5}"

log() { echo "[cneinstance-ready] $*" >&2; }

# --- Gate 1: CRD pre-gate ----------------------------------------------------
wait_for_crd() {
  log "waiting for CRD ${CNE_CRD_NAME} (max ${CRD_TIMEOUT}s)"
  local elapsed=0
  while [ "$elapsed" -lt "$CRD_TIMEOUT" ]; do
    if $KUBECTL get crd "$CNE_CRD_NAME" >/dev/null 2>&1; then
      log "CRD ${CNE_CRD_NAME} present after ${elapsed}s"
      return 0
    fi
    sleep "$CRD_POLL_INTERVAL"
    elapsed=$((elapsed + CRD_POLL_INTERVAL))
  done
  log "ERROR: CRD ${CNE_CRD_NAME} not registered after ${CRD_TIMEOUT}s"
  return 1
}

# --- Readiness predicates (mirror phase25 isCNEReady / cneFunctionallyReady) --

# isCNEReady: status.state ∈ {Ready, Running}. Back-compat with FLO versions
# that populate .status.state.
is_cne_ready() {
  local state
  state="$($KUBECTL -n "$INSTANCE_NAMESPACE" get cneinstance "$INSTANCE_NAME" \
    -o "jsonpath={.status.state}" 2>/dev/null || true)"
  [ "$state" = "Ready" ] || [ "$state" = "Running" ]
}

# cneFunctionallyReady: F5TmmAvailable == True AND CNEControllerAvailable == True.
# Read each sub-condition's status independently via jsonpath; the rollup
# `Available` condition is intentionally never read.
cne_functionally_ready() {
  local tmm ctrl
  tmm="$($KUBECTL -n "$INSTANCE_NAMESPACE" get cneinstance "$INSTANCE_NAME" \
    -o 'jsonpath={.status.conditions[?(@.type=="F5TmmAvailable")].status}' 2>/dev/null || true)"
  ctrl="$($KUBECTL -n "$INSTANCE_NAMESPACE" get cneinstance "$INSTANCE_NAME" \
    -o 'jsonpath={.status.conditions[?(@.type=="CNEControllerAvailable")].status}' 2>/dev/null || true)"
  [ "$tmm" = "True" ] && [ "$ctrl" = "True" ]
}

current_state() {
  $KUBECTL -n "$INSTANCE_NAMESPACE" get cneinstance "$INSTANCE_NAME" \
    -o "jsonpath={.status.state}" 2>/dev/null || true
}

# --- Diagnostics (mirror phase25 dumpPodDiagnostics) -------------------------
dump_pod_diagnostics() {
  log "FAIL diag: dumping pod state in namespace ${INSTANCE_NAMESPACE}"
  local pods
  pods="$($KUBECTL -n "$INSTANCE_NAMESPACE" get pods \
    -o 'jsonpath={range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.status.reason}{"|"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' \
    2>/dev/null || true)"
  if [ -z "$pods" ]; then
    log "FAIL diag: no pods found (or kubectl error) in ${INSTANCE_NAMESPACE}"
    return 0
  fi
  while IFS='|' read -r name phase reason waiting_reason; do
    [ -z "$name" ] && continue
    [ -z "$reason" ] && reason="$waiting_reason"
    log "FAIL diag: pod=${name} phase=${phase} reason=${reason}"
    [ "$phase" = "Running" ] && continue
    local events
    events="$($KUBECTL -n "$INSTANCE_NAMESPACE" get events \
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

# --- Gate 2: condition poll loop ---------------------------------------------
wait_for_ready() {
  log "polling CNEInstance ${INSTANCE_NAMESPACE}/${INSTANCE_NAME} for readiness (max ${CONDITION_TIMEOUT}s, interval ${POLL_INTERVAL}s)"
  local elapsed=0
  while :; do
    if cne_functionally_ready; then
      log "ready: F5TmmAvailable=True AND CNEControllerAvailable=True (state=$(current_state))"
      return 0
    fi
    if is_cne_ready; then
      log "ready via state-fallback: status.state=$(current_state)"
      return 0
    fi
    if [ "$elapsed" -ge "$CONDITION_TIMEOUT" ]; then
      break
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    log "[${elapsed}/${CONDITION_TIMEOUT}s] not ready yet (state=$(current_state))"
  done
  log "ERROR: timeout after ${CONDITION_TIMEOUT}s — CNEInstance ${INSTANCE_NAMESPACE}/${INSTANCE_NAME} last state=$(current_state)"
  dump_pod_diagnostics
  return 1
}

main() {
  wait_for_crd || exit 1
  wait_for_ready || exit 1
  log "CNEInstance ${INSTANCE_NAMESPACE}/${INSTANCE_NAME} is ready"
}

main "$@"
