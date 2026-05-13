# bnk-forge-catalog-aws-eks

BNK Forge catalog for deploying [F5 BIG-IP Next for Kubernetes](https://clouddocs.f5.com/bigip-next-for-kubernetes/) on **AWS EKS**.

> `main` is a **landing page**. The real catalog content (modules, blueprints, vendored shared primitives) lives on the `release/X.Y` branches. Pick the branch that matches the BNK release you want.

## Deploy BNK on AWS EKS

1. Add this repo to Forge as a Module Source (URL above, ref `release/2.2` for BNK 2.2). Forge auto-registers it as a Blueprint Source too.
2. Set up an **AWS credential template** in Forge. Any of Forge's three auth methods works (access keys, profile, or AWS SSO) — they all resolve to the same credential injection at deploy time.
3. Create an AWS project linked to that credential template.
4. Import the `aws-eks-existing-cluster` blueprint and deploy. Forge auto-registers the cluster in its Kubernetes inventory.

Full deploy flow, module inventory, IAM permissions, and credential template variable mapping live in the [release branch README](https://github.com/JLCode-tech/bnk-forge-catalog-aws-eks/blob/release/2.2/README.md).

## Release branches

| Branch | F5 BNK version | Status |
|---|---|---|
| [`release/2.2`](https://github.com/JLCode-tech/bnk-forge-catalog-aws-eks/tree/release/2.2) | BNK 2.2 GA | Active — existing-cluster blueprint partially implemented (register + bnk-prereqs + cert-manager + cert-issuer; FLO + CNEInstance + License pending) |
| `release/2.3` | BNK 2.3 (when GA) | Not yet open |

Past releases are kept on their `release/X.Y` branches indefinitely.

## What you'll find on `release/2.2`

- `modules/eks-cluster-register` — adopt an existing EKS cluster
- `modules/eks-cluster-install-bnk-prereqs` — BNK namespaces + FAR pull secrets + manifest (vendored from `bnk-forge-catalog-shared`)
- `modules/eks-cluster-install-cert-manager` — Jetstack cert-manager (vendored)
- `modules/eks-cluster-install-cert-issuer` — BNK CA + ClusterIssuer (vendored)
- `blueprints/aws-eks-existing-cluster/forge-blueprint.json` — the deploy manifest chaining the above
- `VENDORED.md`, `VENDORED.pin` — vendoring discipline
- `scripts/vendor-refresh.sh`, `.github/workflows/vendor-refresh.yml` — auto-refresh when the shared upstream ships

Modules still to come: `eks-cluster-install-flo` (AWS IRSA), `eks-cluster-cneinstall` (F5BnkGateway chassis for AWS), `eks-cluster-license`, `eks-cluster-create` (alternate provisioning blueprint).

## Related repos

| Repo | Role |
|---|---|
| [`bnk-forge-catalog-shared`](https://github.com/JLCode-tech/bnk-forge-catalog-shared) | Upstream library for the vendored shared modules. |
| [`bnk-forge-modules`](https://github.com/JLCode-tech/bnk-forge-modules) | Legacy/transitional Forge module library. Existing Forge installations may still point there. |
| [`jgruberf5/bnk-forge-ibm-roks-cluster`](https://github.com/jgruberf5/bnk-forge-ibm-roks-cluster) | IBM ROKS catalog (community-maintained reference). |

## Contributing

Open PRs against `release/2.2`. Follow the [BNK Forge Catalog Repo Contract](https://github.com/JLCode-tech/bnk-forge-catalog-shared/blob/release/2.2/CATALOG_REPO_CONTRACT.md) — it covers layout, `bnkforge.pack.json` and `forge-blueprint.json` schemas, vendoring rules, and validation.
