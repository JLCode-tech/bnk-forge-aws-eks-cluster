#!/usr/bin/env bash
#
# run-tests.sh — unit tests for wait-cneinstance-ready.sh against a mock
# `kubectl` stub. No cluster, no AWS.
#
# Run:
#   bash modules/cneinstance-ready-gate/tests/run-tests.sh
#
# Cases (per the acceptance criteria):
#   (a) both conditions True            → exit 0
#   (b) state-fallback (Ready)          → exit 0
#   (c) conditions never True → timeout → exit !=0 AND prints diagnostics
#   (d) only one condition True         → does NOT pass (timeout, exit !=0)
#   (e) Available rollup ignored        → never queried; passes only via subs

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$HERE")"
SCRIPT="$MODULE_DIR/scripts/wait-cneinstance-ready.sh"

# Put the mock on PATH as `kubectl`.
MOCK_BIN="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN"' EXIT
cp "$HERE/mock-kubectl.sh" "$MOCK_BIN/kubectl"
chmod +x "$MOCK_BIN/kubectl"
export PATH="$MOCK_BIN:$PATH"

# Shared fast-poll config so the suite runs in seconds.
export KUBECTL="kubectl"
export INSTANCE_NAMESPACE="f5-operator"
export INSTANCE_NAME="default-f5-cne-controller"
export CNE_CRD_NAME="cneinstances.k8s.f5.com"
export CONDITION_TIMEOUT=2
export CRD_TIMEOUT=2
export POLL_INTERVAL=1
export CRD_POLL_INTERVAL=1

PASS=0
FAIL=0

ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run() {
  # run "<label>"  — relies on the MOCK_* env already exported by the caller.
  OUT_FILE="$(mktemp)"
  bash "$SCRIPT" >"$OUT_FILE" 2>&1
  RC=$?
}

clear_mock() {
  unset MOCK_CRD_PRESENT MOCK_TMM_STATUS MOCK_CTRL_STATUS \
        MOCK_AVAILABLE_STATUS MOCK_STATE MOCK_PODS_JSONPATH \
        MOCK_EVENTS_JSONPATH MOCK_AVAILABLE_PROBE_FILE
}

# --- (a) both conditions True → exit 0 --------------------------------------
clear_mock
export MOCK_CRD_PRESENT=1 MOCK_TMM_STATUS="True" MOCK_CTRL_STATUS="True" MOCK_STATE=""
PROBE="$(mktemp -u)"; export MOCK_AVAILABLE_PROBE_FILE="$PROBE"
run "a"
if [ "$RC" -eq 0 ]; then ok "(a) both conditions True → exit 0"; else bad "(a) expected 0 got $RC"; cat "$OUT_FILE"; fi
if [ ! -e "$PROBE" ]; then ok "(a/e) rollup Available was never queried"; else bad "(e) gate queried the rollup Available condition"; fi

# --- (b) state-fallback (Ready) → exit 0 ------------------------------------
clear_mock
export MOCK_CRD_PRESENT=1 MOCK_TMM_STATUS="" MOCK_CTRL_STATUS="" MOCK_STATE="Ready"
PROBE="$(mktemp -u)"; export MOCK_AVAILABLE_PROBE_FILE="$PROBE"
run "b"
if [ "$RC" -eq 0 ]; then ok "(b) state-fallback Ready → exit 0"; else bad "(b) expected 0 got $RC"; cat "$OUT_FILE"; fi
if grep -q "state-fallback" "$OUT_FILE"; then ok "(b) took the state-fallback path"; else bad "(b) did not log state-fallback"; fi

# --- (c) never ready → timeout → exit !=0 + diagnostics ---------------------
clear_mock
export MOCK_CRD_PRESENT=1 MOCK_TMM_STATUS="False" MOCK_CTRL_STATUS="False" MOCK_STATE="Pending"
export MOCK_PODS_JSONPATH=$'f5-dssm-db-1|Pending|Unschedulable|\nf5-tmm-0|Running||'
export MOCK_EVENTS_JSONPATH=$'FailedScheduling Insufficient cpu\n'
run "c"
if [ "$RC" -ne 0 ]; then ok "(c) timeout → non-zero exit ($RC)"; else bad "(c) expected non-zero, got 0"; fi
if grep -q "FAIL diag: pod=f5-dssm-db-1" "$OUT_FILE"; then ok "(c) dumped pod diagnostics"; else bad "(c) no pod diagnostics"; cat "$OUT_FILE"; fi
if grep -q "Insufficient cpu" "$OUT_FILE"; then ok "(c) dumped pod events for non-Running pod"; else bad "(c) no events for non-Running pod"; fi

# --- (d) only one condition True → no pass ----------------------------------
clear_mock
export MOCK_CRD_PRESENT=1 MOCK_TMM_STATUS="True" MOCK_CTRL_STATUS="False" MOCK_STATE=""
export MOCK_PODS_JSONPATH=$'f5-tmm-0|Running||'
export MOCK_EVENTS_JSONPATH=""
run "d"
if [ "$RC" -ne 0 ]; then ok "(d) single condition True → does NOT pass ($RC)"; else bad "(d) passed with only one condition True"; fi

# --- (e) Available=True but subs False → must NOT pass ----------------------
clear_mock
export MOCK_CRD_PRESENT=1 MOCK_TMM_STATUS="False" MOCK_CTRL_STATUS="False" \
       MOCK_STATE="" MOCK_AVAILABLE_STATUS="True"
export MOCK_PODS_JSONPATH=$'f5-tmm-0|Running||'
PROBE="$(mktemp -u)"; export MOCK_AVAILABLE_PROBE_FILE="$PROBE"
run "e"
if [ "$RC" -ne 0 ]; then ok "(e) Available=True alone → does NOT pass ($RC)"; else bad "(e) passed on the rollup Available condition"; fi
if [ ! -e "$PROBE" ]; then ok "(e) rollup Available was never queried"; else bad "(e) gate queried the rollup Available condition"; fi

# --- CRD pre-gate failure (bonus) -------------------------------------------
clear_mock
export MOCK_CRD_PRESENT=0 MOCK_TMM_STATUS="True" MOCK_CTRL_STATUS="True"
run "crd"
if [ "$RC" -ne 0 ]; then ok "(crd) missing CRD → fail closed ($RC)"; else bad "(crd) passed with no CRD"; fi

echo ""
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
