#!/usr/bin/env bash
#
# run-tests.sh — unit tests for wait-license-active.sh against a mock `kubectl`
# stub. No cluster, no AWS.
#
# Run:
#   bash modules/license-activation-gate/tests/run-tests.sh
#
# Cases (per the acceptance criteria):
#   (a) state becomes Active                  → applies the CR, exit 0
#   (b) never Active → timeout                → exit !=0 AND prints diagnostics
#   (c) NotActivated / empty / Failed         → does NOT pass (timeout, exit !=0)
#   (d) CRD missing pre-gate                  → fail closed (exit !=0)
#   (e) the mock confirms a `kubectl apply` of a `kind: License` was issued
#       (and the JWT lands in the manifest file, NEVER on argv)

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$(dirname "$HERE")"
SCRIPT="$MODULE_DIR/scripts/wait-license-active.sh"

# Put the mock on PATH as `kubectl`.
MOCK_BIN="$(mktemp -d)"
trap 'rm -rf "$MOCK_BIN"' EXIT
cp "$HERE/mock-kubectl.sh" "$MOCK_BIN/kubectl"
chmod +x "$MOCK_BIN/kubectl"
export PATH="$MOCK_BIN:$PATH"

# A rendered License CR with the __JWT__ placeholder, exactly as main.tf passes
# it. The JWT is a sentinel so the test can assert it never reaches argv.
SENTINEL_JWT="JWT-SENTINEL-do-not-leak-eyJhbGci"
export LICENSE_MANIFEST=$'apiVersion: k8s.f5net.com/v1\nkind: License\nmetadata:\n  name: bnk-license\n  namespace: f5-operator\nspec:\n  operationMode: connected\n  jwt: __JWT__\n  teemCertUrl: https://product.apis.f5.com/ee/v1\n'
export LICENSE_JWT="$SENTINEL_JWT"

# Shared fast-poll config so the suite runs in seconds.
export KUBECTL="kubectl"
export LICENSE_NAMESPACE="f5-operator"
export LICENSE_NAME="bnk-license"
export LICENSE_CRD_NAME="licenses.k8s.f5net.com"
export ACTIVATION_TIMEOUT=2
export CRD_TIMEOUT=2
export POLL_INTERVAL=1
export CRD_POLL_INTERVAL=1

PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run() {
  # run — relies on the MOCK_* env already exported by the caller.
  OUT_FILE="$(mktemp)"
  bash "$SCRIPT" >"$OUT_FILE" 2>&1
  RC=$?
}

clear_mock() {
  unset MOCK_CRD_PRESENT MOCK_STATE MOCK_APPLY_FAIL \
        MOCK_PODS_JSONPATH MOCK_EVENTS_JSONPATH MOCK_APPLY_LOG
}

# --- (a) state Active → applies CR then exit 0 ------------------------------
clear_mock
export MOCK_CRD_PRESENT=1 MOCK_STATE="Active"
APPLY_LOG="$(mktemp)"; export MOCK_APPLY_LOG="$APPLY_LOG"
run
if [ "$RC" -eq 0 ]; then ok "(a) state Active → exit 0"; else bad "(a) expected 0 got $RC"; cat "$OUT_FILE"; fi

# --- (e) a `kubectl apply` of a kind: License was issued --------------------
if grep -q "ARGV: kubectl apply" "$APPLY_LOG"; then ok "(e) kubectl apply was invoked"; else bad "(e) no kubectl apply recorded"; fi
if grep -q "kind: License" "$APPLY_LOG"; then ok "(e) applied manifest is kind: License"; else bad "(e) applied manifest was not a License"; fi
if grep -q "$SENTINEL_JWT" "$APPLY_LOG"; then ok "(e) JWT reached the manifest file (correctly substituted)"; else bad "(e) JWT was not substituted into the manifest"; fi
# JWT-safety: the JWT must be in the manifest body, NEVER on the apply argv line.
if grep "ARGV: kubectl apply" "$APPLY_LOG" | grep -q "$SENTINEL_JWT"; then bad "(e) JWT LEAKED onto kubectl argv"; else ok "(e) JWT never appears on kubectl argv"; fi

# --- (b) never Active → timeout → exit !=0 + diagnostics --------------------
clear_mock
export MOCK_CRD_PRESENT=1 MOCK_STATE="NotActivated"
export MOCK_PODS_JSONPATH=$'f5-cwc-0|Pending|Unschedulable|\nf5-flo-0|Running||'
export MOCK_EVENTS_JSONPATH=$'FailedScheduling Insufficient memory\n'
run
if [ "$RC" -ne 0 ]; then ok "(b) timeout → non-zero exit ($RC)"; else bad "(b) expected non-zero, got 0"; fi
if grep -q "FAIL diag: pod=f5-cwc-0" "$OUT_FILE"; then ok "(b) dumped pod diagnostics"; else bad "(b) no pod diagnostics"; cat "$OUT_FILE"; fi
if grep -q "Insufficient memory" "$OUT_FILE"; then ok "(b) dumped events for non-Running pod"; else bad "(b) no events for non-Running pod"; fi

# --- (c) NotActivated / empty / Failed → no pass ----------------------------
for state_val in "" "NotActivated" "Failed"; do
  clear_mock
  export MOCK_CRD_PRESENT=1 MOCK_STATE="$state_val"
  export MOCK_PODS_JSONPATH=$'f5-flo-0|Running||'
  run
  label="${state_val:-<empty>}"
  if [ "$RC" -ne 0 ]; then ok "(c) state=$label → does NOT pass ($RC)"; else bad "(c) passed on non-Active state '$label'"; fi
done

# --- (d) CRD missing pre-gate → fail closed ---------------------------------
clear_mock
export MOCK_CRD_PRESENT=0 MOCK_STATE="Active"
APPLY_LOG="$(mktemp)"; export MOCK_APPLY_LOG="$APPLY_LOG"
run
if [ "$RC" -ne 0 ]; then ok "(d) missing CRD → fail closed ($RC)"; else bad "(d) passed with no CRD"; fi
if grep -q "ARGV: kubectl apply" "$APPLY_LOG"; then bad "(d) applied the CR despite missing CRD"; else ok "(d) did not apply the CR before the CRD existed"; fi

# --- (apply-fail) kubectl apply fails → fail closed -------------------------
clear_mock
export MOCK_CRD_PRESENT=1 MOCK_STATE="Active" MOCK_APPLY_FAIL=1
run
if [ "$RC" -ne 0 ]; then ok "(apply-fail) apply error → fail closed ($RC)"; else bad "(apply-fail) passed despite apply failure"; fi

echo ""
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
