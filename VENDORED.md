# Vendored modules

Some modules in this repository are **vendored copies** of upstream modules from [`JLCode-tech/bnk-forge-catalog-shared`](https://github.com/JLCode-tech/bnk-forge-catalog-shared) — they are not authored here. The canonical source lives in `bnk-forge-catalog-shared`; this repo carries pinned copies that are refreshed when the upstream ships a new release.

## Why vendor?

- Forge's source-sync model walks each repo independently. Cross-repo module references aren't supported, so per-cloud repos that need the shared k8s primitives carry them locally.
- Vendoring gives each per-cloud repo a deterministic, immutable snapshot of the shared layer at a known BNK release point.
- Refreshes are mechanical and automated — no per-cloud manual upkeep.

## What's vendored

| Local module path | Upstream source |
| --- | --- |
| `modules/eks-cluster-install-bnk-prereqs` | `k8s/bnk-prerequisites` |
| `modules/eks-cluster-install-cert-manager` | `k8s/cert-manager` |
| `modules/eks-cluster-install-cert-issuer` | `k8s/bnk-cert-issuer` |

The current pin is recorded in [`VENDORED.pin`](./VENDORED.pin) at the repo root.

## Rules for vendored modules

1. **Do not hand-edit files inside a vendored module.** The next vendor refresh will clobber any local changes. If you need AWS-specific tuning, put it in a separate wrapper module that invokes the vendored one — never in the vendored tree.
2. **Path and dependency rewrites are mechanical and reversible.** When `scripts/vendor-refresh.sh` copies a module in, it rewrites `module.path` in the pack JSON and any `dependencies.required[].module` references to point at this repo's module names. These rewrites are pure functions of the path map in the script.
3. **Tags `vendored` and `aws_eks` are auto-applied** to the pack JSON's `module.tags` so vendored modules are distinguishable in the Forge catalog.

## Refreshing the vendored copies

### Automatic (preferred)

The `.github/workflows/vendor-refresh.yml` workflow runs:

- **Weekly** — Monday 06:00 UTC (safety net catch-up)
- **On dispatch** — when `bnk-forge-catalog-shared` pushes to a `release/*` branch, its `notify-downstream.yml` workflow dispatches a `bnk-forge-modules-released` event to this repo, which triggers an immediate refresh
- **Manually** — via the GitHub Actions UI ("Run workflow")

If the refresh finds drift, it opens a PR titled `chore: vendor-refresh from bnk-forge-modules@<ref>`. Review the diff and merge.

### Manual

Run the script locally:

```bash
./scripts/vendor-refresh.sh
# or to refresh from a different ref:
UPSTREAM_REF=release/2.3 ./scripts/vendor-refresh.sh
```

Inspect `git diff modules/ VENDORED.pin`, commit, and push.

## Versioning model

This repo's branches track BNK release cadence (`release/2.2`, `release/2.3`, …). Each branch's vendored content is pinned to the corresponding `bnk-forge-catalog-shared` branch. When BNK 2.3 ships:

1. `bnk-forge-catalog-shared` cuts a `release/2.3` branch with 2.3 content.
2. A `release/2.3` branch is created here, pointing the vendor pin at `bnk-forge-modules@release/2.3`.
3. The vendor-refresh workflow propagates the upstream content into this repo's `release/2.3` branch.

Old branches keep pointing at their original pin — `release/2.2` here stays pinned to `bnk-forge-modules@release/2.2` forever.
