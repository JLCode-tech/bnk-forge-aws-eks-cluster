#!/usr/bin/env bash
#
# mock-kubectl.sh — a canned `kubectl` stub for unit-testing
# wait-license-active.sh. Placed on PATH as `kubectl` by run-tests.sh.
#
# It pattern-matches the exact invocations the script makes and emits canned
# output driven by these env vars:
#
#   MOCK_CRD_PRESENT     "1" → `get crd` exits 0 (CRD registered), else exits 1
#   MOCK_STATE           value for the .status.state jsonpath (e.g. "Active")
#   MOCK_APPLY_FAIL      "1" → `apply` exits 1 (simulate an apply failure)
#   MOCK_PODS_JSONPATH   canned output for `get pods -o jsonpath=...`
#   MOCK_EVENTS_JSONPATH canned output for `get events ... -o jsonpath=...`
#
# It also records every `kubectl apply` so the test can prove a `kind: License`
# was actually applied (and that the JWT was NOT leaked to argv):
#   MOCK_APPLY_LOG       path to append apply argv + manifest body to.

set -u

args="$*"

# --- apply: record it (and the manifest body) so tests can assert on it ------
case "$args" in
  *"apply"*)
    if [ -n "${MOCK_APPLY_LOG:-}" ]; then
      {
        echo "ARGV: kubectl $args"
        # Find the -f <file> argument and dump the manifest body so the test can
        # confirm kind: License was applied. The JWT must be in the file, NEVER
        # in argv.
        prev=""
        for a in "$@"; do
          if [ "$prev" = "-f" ] && [ -f "$a" ]; then
            echo "MANIFEST<<"
            cat "$a"
            echo ">>MANIFEST"
          fi
          prev="$a"
        done
      } >> "$MOCK_APPLY_LOG"
    fi
    if [ "${MOCK_APPLY_FAIL:-0}" = "1" ]; then
      echo "mock-kubectl: simulated apply failure" >&2
      exit 1
    fi
    echo "license.k8s.f5net.com/bnk-license serverside-applied"
    exit 0
    ;;
esac

case "$args" in
  *"get crd"*)
    if [ "${MOCK_CRD_PRESENT:-1}" = "1" ]; then
      echo "licenses.k8s.f5net.com"
      exit 0
    fi
    exit 1
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
