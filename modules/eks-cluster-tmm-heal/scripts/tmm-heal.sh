#!/usr/bin/env bash
# =============================================================================
# tmm-heal.sh — best-effort cold-start heals (awsbnkctl phase24 / 24b / 24c)
# =============================================================================
# BNK 2.3 has three known cold-start races that can leave the control plane (and
# therefore TMM) wedged on a fresh cluster. None are gates — every path exits 0;
# the ready-gate that follows is the real check. Porting these into the chain
# removes the wedges the live D-031 retrofit kept hitting.
#
#   phase24  (cwc DNS-warmup): the f5-spk-cwc pod in f5-cne-core crash-loops on
#            DNS warm-up; force-delete it once restarts >= 3 to break the loop.
#   phase24b (dssm --insecure overlay): redis-cli 8.x strict-verifies the dssm
#            TLS hostname; the cert SAN doesn't cover 127.0.0.1, so the replica
#            probe fails for 12+ min. Patch the f5-dssm ConfigMap to add
#            --insecure to redis-cli --tls calls, then bounce the dssm pods.
#   phase24c (pod-manager): the f5-tmm-pod-manager sidecar in f5-cne-controller
#            races kube-proxy on a cold node and CrashLoops; rollout-restart the
#            controller (up to 2 bounces) so it re-binds once kube-proxy is up.
#
# Inputs (environment): EKS_CLUSTER_NAME, AWS_REGION, AWS_ACCESS_KEY_ID,
#   AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN (optional), OPERATOR_NAMESPACE
#   (f5-cne-core), INSTANCE_NAMESPACE (f5-cne-system), KUBECONFIG_OUT.
set -uo pipefail   # NOT -e: best-effort, never abort the deploy on a heal hiccup

log() { echo "[tmm-heal] $*" >&2; }

OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-f5-cne-core}"
INSTANCE_NAMESPACE="${INSTANCE_NAMESPACE:-f5-cne-system}"
export AWS_REGION AWS_DEFAULT_REGION="${AWS_REGION:-}"

aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
  --kubeconfig "$KUBECONFIG_OUT" >&2 2>/dev/null || { log "could not refresh kubeconfig; skipping heals"; exit 0; }
KC="kubectl --kubeconfig $KUBECONFIG_OUT"

# --- phase24: cwc DNS-warmup heal -------------------------------------------
cwc_heal() {
  log "phase24: cwc DNS-warmup heal (force-delete on restartCount>=3)"
  local i pod ready rc
  for i in $(seq 1 12); do
    pod="$($KC -n "$OPERATOR_NAMESPACE" get pods -l app=cwc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [ -z "$pod" ]; then sleep 15; continue; fi
    ready="$($KC -n "$OPERATOR_NAMESPACE" get pod "$pod" -o jsonpath='{.status.containerStatuses[?(@.name=="f5-spk-cwc")].ready}' 2>/dev/null)"
    rc="$($KC -n "$OPERATOR_NAMESPACE" get pod "$pod" -o jsonpath='{.status.containerStatuses[?(@.name=="f5-spk-cwc")].restartCount}' 2>/dev/null)"
    rc="${rc:-0}"
    if [ "$ready" = "true" ]; then log "cwc Ready (restarts=$rc) — no heal"; return; fi
    if [ "$rc" -ge 3 ] 2>/dev/null; then
      log "cwc restartCount=$rc >= 3 — force-deleting $pod"
      $KC -n "$OPERATOR_NAMESPACE" delete pod "$pod" --grace-period=0 --force >&2 2>/dev/null || true
      sleep 20
    else
      sleep 15
    fi
  done
  log "phase24: cwc heal window exhausted (best-effort)"
}

# --- phase24b: dssm --insecure overlay --------------------------------------
dssm_overlay() {
  log "phase24b: dssm --insecure TLS overlay"
  # Skip if all dssm pods are already Ready (cold-start-only fix).
  local total ready
  total="$($KC -n "$INSTANCE_NAMESPACE" get pods -l 'app in (f5-dssm-db,f5-dssm-sentinel)' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  ready="$($KC -n "$INSTANCE_NAMESPACE" get pods -l 'app in (f5-dssm-db,f5-dssm-sentinel)' \
            -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c true)"
  if [ "${total:-0}" -gt 0 ] && [ "${ready:-0}" -eq "${total:-0}" ]; then
    log "all $total dssm pods Ready — skipping overlay"; return
  fi
  # Wait for FLO to create the f5-dssm ConfigMap.
  local i found=""
  for i in $(seq 1 18); do
    if $KC -n "$INSTANCE_NAMESPACE" get configmap f5-dssm >/dev/null 2>&1; then found="yes"; break; fi
    sleep 10
  done
  if [ -z "$found" ]; then log "f5-dssm ConfigMap not found — skipping overlay"; return; fi

  local tmp; tmp="$(mktemp)"
  $KC -n "$INSTANCE_NAMESPACE" get configmap f5-dssm -o json > "$tmp" 2>/dev/null || { log "could not read f5-dssm cm"; return; }
  if grep -q -- '--tls --insecure' "$tmp"; then log "f5-dssm already has --tls --insecure — skipping"; rm -f "$tmp"; return; fi
  if ! grep -q -- '--tls ' "$tmp"; then log "f5-dssm has no --tls invocations — nothing to patch"; rm -f "$tmp"; return; fi

  # Patch every data value: " --tls " -> " --tls --insecure ".
  local patched; patched="$(jq '.data |= with_entries(.value |= gsub(" --tls "; " --tls --insecure "))' "$tmp")"
  printf '%s' "$patched" | $KC apply -f - >&2 2>/dev/null && log "patched f5-dssm ConfigMap (--insecure)" || { log "patch apply failed"; rm -f "$tmp"; return; }
  rm -f "$tmp"
  log "bouncing dssm pods to remount patched ConfigMap"
  $KC -n "$INSTANCE_NAMESPACE" delete pods -l 'app in (f5-dssm-db,f5-dssm-sentinel)' --grace-period=0 --force >&2 2>/dev/null || true
}

# --- phase24c: f5-tmm-pod-manager cold-start heal ---------------------------
pm_heal() {
  log "phase24c: f5-tmm-pod-manager cold-start heal (rollout-restart on wedge, max 2 bounces)"
  local bounces=0 seen_ready="" i
  for i in $(seq 1 12); do
    local sel pods wedged="" any_ready=""
    sel="$($KC -n "$INSTANCE_NAMESPACE" get deploy f5-cne-controller -o jsonpath='{.spec.selector.matchLabels.app}' 2>/dev/null)"
    if [ -z "$sel" ]; then log "f5-cne-controller not found yet (t=$((i*30))s)"; sleep 30; continue; fi
    pods="$($KC -n "$INSTANCE_NAMESPACE" get pods -l "app=$sel" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
    [ -z "$pods" ] && { sleep 30; continue; }
    local p ready rc reason
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      ready="$($KC -n "$INSTANCE_NAMESPACE" get pod "$p" -o jsonpath='{.status.containerStatuses[?(@.name=="f5-tmm-pod-manager")].ready}' 2>/dev/null)"
      rc="$($KC -n "$INSTANCE_NAMESPACE" get pod "$p" -o jsonpath='{.status.containerStatuses[?(@.name=="f5-tmm-pod-manager")].restartCount}' 2>/dev/null)"
      reason="$($KC -n "$INSTANCE_NAMESPACE" get pod "$p" -o jsonpath='{.status.containerStatuses[?(@.name=="f5-tmm-pod-manager")].state.waiting.reason}' 2>/dev/null)"
      rc="${rc:-0}"
      [ "$ready" = "true" ] && any_ready="yes"
      if [ "$reason" = "CrashLoopBackOff" ] || { [ "$rc" -ge 2 ] 2>/dev/null && [ "$ready" != "true" ]; }; then wedged="yes"; fi
    done <<EOF
$pods
EOF
    [ -n "$any_ready" ] && { [ -z "$seen_ready" ] && log "pod-manager Ready"; seen_ready="yes"; }
    if [ -n "$wedged" ] && [ "$bounces" -lt 2 ]; then
      bounces=$((bounces + 1))
      log "pod-manager wedged — rollout-restart f5-cne-controller (bounce $bounces/2)"
      $KC -n "$INSTANCE_NAMESPACE" rollout restart deploy/f5-cne-controller >&2 2>/dev/null || true
      sleep 60
      continue
    fi
    # Healthy and stable: exit early once Ready and not wedged.
    [ -n "$seen_ready" ] && [ -z "$wedged" ] && { log "pod-manager stable — done"; return; }
    sleep 30
  done
  log "phase24c: window exhausted (bounces=$bounces, best-effort)"
}

cwc_heal
dssm_overlay
pm_heal
log "all heals complete (best-effort)"
exit 0
