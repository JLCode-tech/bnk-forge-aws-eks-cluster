# BNK Forge — AWS EKS Cluster

Forge-ready AWS EKS content covering the full BNK install on top of an
AWS-managed Elastic Kubernetes Service cluster:

1. **Get a cluster** — either provision one or reference an existing one.
2. **Install cert-manager.**
3. **Install BNK prerequisites** (namespaces, FAR pull secrets, manifest).
4. **Install the F5 Lifecycle Operator (FLO).**
5. **Deploy a CNEInstance.**
6. **Apply the BNK License.**

Each step is its own Forge-ready module; two blueprints chain them together end-to-end.

## Modules

| Module path | Purpose |
| ----------- | ------- |
| `modules/eks-cluster-create` | Create an AWS EKS cluster (VPC, subnets, node groups, OIDC provider, cluster add-ons). Emits the outputs BNK Forge needs to register the cluster, plus the kubeconfig. *(not yet implemented)* |
| `modules/eks-cluster-register` | Resolve an existing AWS EKS cluster by name and emit the same registration outputs + kubeconfig. |
| `modules/eks-cluster-install-bnk-prereqs` | Create BNK namespaces, FAR image pull secrets, download the BNK manifest. Vendored from `bnk-forge-catalog-shared`. |
| `modules/eks-cluster-install-cert-manager` | Install cert-manager (Helm chart, BNK-compatible defaults). Vendored from `bnk-forge-catalog-shared`. |
| `modules/eks-cluster-install-cert-issuer` | Create the BNK-managed self-signed CA and ClusterIssuer. Vendored from `bnk-forge-catalog-shared`. |
| `modules/eks-cluster-install-flo` | Install F5 Lifecycle Operator with AWS-tuned defaults (IRSA, NAD setup). *(not yet implemented)* |
| `modules/eks-cluster-cneinstall` | Deploy a `CNEInstance` custom resource with AWS-specific chassis configuration (auto-creates the `F5BnkGateway` chassis CR for AWS/EKS). *(not yet implemented)* |
| `modules/eks-cluster-license` | Apply the BNK License CR. *(not yet implemented)* |

## Blueprints

| Blueprint | Module chain |
| --------- | ------------ |
| `blueprints/aws-eks-cluster-create` | `cluster-create` → `cert-manager` → `bnk-prereqs` → `flo` → `cneinstance` → `license` *(not yet implemented)* |
| `blueprints/aws-eks-existing-cluster` | `cluster-register` → `bnk-prereqs` → `cert-manager` → `cert-issuer` → `flo` → `cneinstance` → `license` |

Both blueprints set explicit `order` on every input so the deploy form follows the deployment flow: AWS credentials → cluster identity → cert-manager → BNK prereqs → FLO → CNEInstance → License.

## Repo model

This is a **long-lived repo** with **branches per BNK release**:

- `release/2.2` — BNK 2.2 content
- `release/2.3` — BNK 2.3 content *(future)*
- `release/2.4`, `release/3.x` — as BNK ships them

`main` tracks the most recent release branch. Customers select which BNK version they want by pointing Forge's Module Source at the matching branch or tag.

## Shared k8s primitives

The shared cloud-agnostic Kubernetes primitives (`bnk-prerequisites`, `cert-manager`, `bnk-cert-issuer`) live in [`bnk-forge-catalog-shared`](https://github.com/JLCode-tech/bnk-forge-catalog-shared). This repo **vendors** them at a pinned tag — when `bnk-forge-catalog-shared` ships a new release tag, a vendor-refresh PR re-copies them in. `bnk-forge-catalog-shared` remains the canonical source; Forge never has to resolve cross-repo module references.

## AWS Credential Template compatibility

Every module and both blueprints use the BNK Forge AWS credential-template variable names:

- `aws_access_key_id`
- `aws_secret_access_key`
- `aws_session_token` *(optional, for STS-assumed-role)*
- `aws_region`

That lets BNK Forge prefill these values from the selected AWS Credential Template in both flows:

- **Add Module to Project**
- **Imported Blueprint deployment**

## BNK registration outputs

The `eks-cluster-create` and `eks-cluster-register` modules emit the fields BNK Forge needs to auto-register the cluster in the Kubernetes inventory:

- `cluster_name`
- `cluster_id` (EKS cluster ARN)
- `cluster_endpoint`
- `region`
- `kubeconfig` (base64-encoded; bnk-forge adopts it on first scan)

After apply succeeds, BNK Forge auto-registers the cluster — no manual step required.

## Import into BNK Forge

1. Add this repository as both a **Module Source** and a **Blueprint Source** and sync it.
2. Import the blueprint that fits your scenario:
   - `aws-eks-cluster-create` for new clusters.
   - `aws-eks-existing-cluster` for clusters that already exist.
3. Deploy the imported blueprint into an AWS project that is linked to an AWS Credential Template.
4. After apply succeeds, BNK Forge will register the cluster on its Kubernetes page automatically.
