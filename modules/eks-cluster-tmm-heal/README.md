# eks-cluster-tmm-heal

Best-effort BNK 2.3 cold-start heals, ported from awsbnkctl phases 24 / 24b / 24c.
Runs **after** `cneinstall` and **before** the readiness gate. Never a gate — the
script always exits 0; the ready-gate that follows is the real check.

## What it heals

| Phase | Symptom (cold cluster) | Action |
|-------|------------------------|--------|
| 24 — cwc DNS-warmup | `f5-spk-cwc` (f5-cne-core) crash-loops on DNS warm-up | force-delete the pod once `restartCount >= 3` |
| 24b — dssm `--insecure` | redis-cli 8.x strict-verifies the dssm TLS hostname; SAN doesn't cover `127.0.0.1`, replica probe fails 12+ min | patch the `f5-dssm` ConfigMap (`--tls` → `--tls --insecure`), bounce dssm pods |
| 24c — pod-manager | `f5-tmm-pod-manager` sidecar in `f5-cne-controller` races kube-proxy on a cold node, CrashLoops | rollout-restart the controller (≤ 2 bounces) |

All three are idempotent and skip when the target is already healthy. See ADR
**D-033** (host-device TMM dataplane).

## Inputs

`aws_*` credentials + `aws_region`, `eks_cluster_name` (refreshes an exec-auth
kubeconfig), `operator_namespace` (f5-cne-core), `instance_namespace`
(f5-cne-system), `cneinstall_ready` (ordering gate).

## Outputs

`heal_applied` — true once the heals have run (the readiness gate depends on it).
