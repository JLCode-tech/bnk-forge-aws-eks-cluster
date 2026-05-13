# bnk-forge-catalog-aws-eks

BNK Forge catalog for deploying [F5 BIG-IP Next for Kubernetes](https://clouddocs.f5.com/bigip-next-for-kubernetes/latest/) on **AWS EKS**.

## Deploy BNK on AWS EKS

The intended user flow, end-to-end:

1. **In Forge → Settings → Module Sources**, add this repo:
   - URL: `https://github.com/JLCode-tech/bnk-forge-catalog-aws-eks.git`
   - Ref: the `release/2.x` branch matching the BNK version you want (`release/2.2` today)
   - Forge auto-registers it as both a Module Source *and* a Blueprint Source.
2. **In Forge → Settings → Credential Templates**, set up an **AWS credential template** that supplies `aws_access_key_id`, `aws_secret_access_key`, and `aws_region` (plus optional `aws_session_token` for STS-assumed roles).
3. **In Forge → Projects**, create an AWS project linked to that credential template.
4. **In Forge → Blueprints**, import the blueprint that fits your scenario (see [Blueprints](#blueprints) below) and deploy into your project.

After apply succeeds, Forge auto-registers your EKS cluster in its Kubernetes inventory — no manual scan or kubeconfig handoff step.

## Blueprints

| Blueprint | When to use | Status |
|---|---|---|
| [`blueprints/aws-eks-existing-cluster`](./blueprints/aws-eks-existing-cluster) | You already have an EKS cluster (provisioned by Terraform, the AWS console, eksctl, etc.) and want Forge to adopt it and lay down the BNK stack on top. | Implemented through cert-issuer; FLO + CNEInstance + License pending |
| `blueprints/aws-eks-cluster-create` | You want Forge to provision a new EKS cluster end-to-end (VPC, subnets, node groups, BNK stack). | Not yet implemented |

## Modules

Implementation status across the AWS-specific deployment chain:

| Module | Role | Status |
|---|---|---|
| [`modules/eks-cluster-register`](./modules/eks-cluster-register) | Adopt an existing EKS cluster; emit BNK registration outputs. | Implemented (AWS-specific, written in this repo) |
| [`modules/eks-cluster-install-bnk-prereqs`](./modules/eks-cluster-install-bnk-prereqs) | Namespaces, FAR pull secrets, BNK manifest download. | Implemented (vendored from `bnk-forge-catalog-shared`) |
| [`modules/eks-cluster-install-cert-manager`](./modules/eks-cluster-install-cert-manager) | Jetstack cert-manager install. | Implemented (vendored) |
| [`modules/eks-cluster-install-cert-issuer`](./modules/eks-cluster-install-cert-issuer) | BNK self-signed CA + ClusterIssuer. | Implemented (vendored) |
| `modules/eks-cluster-install-flo` | F5 Lifecycle Operator install with AWS IRSA for the FLO controller and BIG-IP CIS service account. | Not yet implemented |
| `modules/eks-cluster-cneinstall` | CNEInstance CR with AWS-specific `F5BnkGateway` chassis logic and ENA/SR-IOV chassis config. | Not yet implemented |
| `modules/eks-cluster-license` | BNK License CR. | Not yet implemented |
| `modules/eks-cluster-create` | VPC + subnets + EKS cluster + node groups (provisioning, alternate to register). | Not yet implemented |

## AWS credential template

Every module and blueprint in this repo expects these names, which match the Forge AWS credential template fields:

| Variable | Source | Sensitive |
|---|---|---|
| `aws_access_key_id` | Credential template | Yes |
| `aws_secret_access_key` | Credential template | Yes |
| `aws_region` | Project (`region` field) | No |
| `aws_session_token` | Credential template (optional, STS-assumed-role only) | Yes |
| `cne_pull_secret` | Project secret — base64 F5 FAR service account JSON or dockerconfigjson | Yes |

## IAM permissions

**For the deployer (the IAM principal whose credentials Forge uses):**

The `eks-cluster-register` module needs at minimum:
- `eks:DescribeCluster` on the target cluster
- `sts:GetCallerIdentity`

When the install modules ship, FLO with IRSA will additionally need:
- `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:CreateOpenIDConnectProvider` (or equivalent if the OIDC provider is pre-created)

**For the EKS cluster:**

The deployer principal must be mapped into the cluster's `aws-auth` ConfigMap (or use EKS access entries on clusters that have them enabled) for `system:masters` or another role that can apply CRDs and namespaces.

## Branch model

This repo carries one branch per BNK release: `release/2.2`, future `release/2.3`, etc. `main` tracks the most recent release branch. Point your Forge Module Source at the branch matching your BNK version.

## Vendored shared modules

Three of the modules here (`eks-cluster-install-bnk-prereqs`, `eks-cluster-install-cert-manager`, `eks-cluster-install-cert-issuer`) are **vendored** from [`bnk-forge-catalog-shared`](https://github.com/JLCode-tech/bnk-forge-catalog-shared) — they're not authored here. The current pin is in [`VENDORED.pin`](./VENDORED.pin); the discipline and refresh model are in [`VENDORED.md`](./VENDORED.md).

A vendor-refresh PR is opened automatically when `bnk-forge-catalog-shared` ships changes — `.github/workflows/vendor-refresh.yml` listens for the upstream's `bnk-forge-modules-released` dispatch and runs `scripts/vendor-refresh.sh`. A weekly Monday cron acts as a safety net.

**Do not hand-edit files inside a vendored module's directory** — they'll be clobbered on the next refresh. AWS-specific tuning belongs in a separate wrapper module.

## Contributing

This repo follows the [BNK Forge Catalog Repo Contract](https://github.com/JLCode-tech/bnk-forge-catalog-shared/blob/release/2.2/CATALOG_REPO_CONTRACT.md). Read it before opening a PR.

## Related repos

- [`bnk-forge-catalog-shared`](https://github.com/JLCode-tech/bnk-forge-catalog-shared) — upstream library for the vendored shared modules.
- [`bnk-forge-modules`](https://github.com/JLCode-tech/bnk-forge-modules) — legacy/transitional source; existing Forge installations may still point there.
- [`jgruberf5/bnk-forge-ibm-roks-cluster`](https://github.com/jgruberf5/bnk-forge-ibm-roks-cluster) — IBM ROKS catalog (community-maintained reference).
