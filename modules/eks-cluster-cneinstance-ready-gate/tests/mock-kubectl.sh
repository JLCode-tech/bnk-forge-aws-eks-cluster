#!/usr/bin/env bash
#
# mock-kubectl.sh — a canned `kubectl` stub for unit-testing
# wait-cneinstance-ready.sh. Placed on PATH as `kubectl` by run-tests.sh.
#
# It pattern-matches the exact invocations the script makes and emits canned
# output driven by these env vars:
#
#   MOCK_CRD_PRESENT       "1" → `get crd` exits 0 (CRD registered), else exits 1
#   MOCK_TMM_STATUS        value for the F5TmmAvailable jsonpath  (e.g. "True")
#   MOCK_CTRL_STATUS       value for the CNEControllerAvailable jsonpath
#   MOCK_AVAILABLE_STATUS  value for an Available-rollup jsonpath, if the script
#                          ever reads it — it must NOT. If the script queries
#                          Available, the mock writes a sentinel file so the
#                          test can assert the rollup was never consulted.
#   MOCK_STATE             value for the .status.state jsonpath
#   MOCK_PODS_JSONPATH     canned output for `get pods -o jsonpath=...`
#   MOCK_EVENTS_JSONPATH   canned output for `get events ... -o jsonpath=...`
#   MOCK_AVAILABLE_PROBE_FILE  path to touch if Available is ever queried

set -u

args="$*"

case "$args" in
  *"get crd"*)
    if [ "${MOCK_CRD_PRESENT:-1}" = "1" ]; then
      echo "cneinstances.k8s.f5.com"
      exit 0
    fi
    exit 1
    ;;
esac

case "$args" in
  *'F5TmmAvailable'*)
    printf '%s' "${MOCK_TMM_STATUS:-}"
    exit 0
    ;;
  *'CNEControllerAvailable'*)
    printf '%s' "${MOCK_CTRL_STATUS:-}"
    exit 0
    ;;
  *'@.type=="Available"'*|*'type=="Available"'*)
    # The gate must never read the rollup Available condition. Record the
    # violation so the test can fail.
    [ -n "${MOCK_AVAILABLE_PROBE_FILE:-}" ] && touch "$MOCK_AVAILABLE_PROBE_FILE"
    printf '%s' "${MOCK_AVAILABLE_STATUS:-}"
    exit 0
    ;;
  *'.status.state'*)
    printf '%s' "${MOCK_STATE:-}"
    exit 0
    ;;
  *"get pods"*)
    printf '%s' "${MOCK_PODS_JSONPATH:-}"
    exit 0
    ;;
  *"get events"*)
    printf '%s' "${MOCK_EVENTS_JSONPATH:-}"
    exit 0
    ;;
esac

# Unrecognised call — fail loudly so tests surface unexpected kubectl usage.
echo "mock-kubectl: unexpected call: kubectl $args" >&2
exit 99
