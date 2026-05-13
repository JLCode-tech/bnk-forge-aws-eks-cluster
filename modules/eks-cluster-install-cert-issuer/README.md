# BNK Cert Issuer

Creates Forge-managed self-signed CA and ClusterIssuer resources for BNK cert-manager flows.

## Description

This module is a Python-runtime manifest module. The actual manifests are rendered by the backend engine at `backend/modules/k8s/bnk_cert_issuer.py`. This pack entry exists so the module catalog sync discovers and registers the module in the library.

The canonical deployment source for this module is `bnkforge.pack.json` + `manifests/*.yaml`:

- `01-selfsigned-issuer.yaml` — bootstrap self-signed ClusterIssuer
- `02-ca-certificate.yaml` — CA certificate in cert-manager namespace
- `03-ca-cluster-issuer.yaml` — CA-backed ClusterIssuer
- `04-otel-certificate.yaml` — OTEL server certificate in BNK instance namespace
- `05-otel-f5ing-certificate.yaml` — OTEL F5-ingestion certificate in BNK instance namespace

OTEL certificates include explicit SAN/DNS identities derived from the cert name +
instance namespace convention used across BNK manifests:

- `<cert-name>`
- `<cert-name>.<instance-namespace>`
- `<cert-name>.<instance-namespace>.svc`
- `<cert-name>.<instance-namespace>.svc.cluster.local`

This follows in-repo cert-manager patterns where in-cluster TLS certificates use
service DNS SANs (`*.svc`) and aligns with the existing OTEL resource naming
contract (`external-otelsvr*`, `external-f5ingotelsvr*`).

## Dependencies

- `k8s/cert-manager` — CRDs must exist before ClusterIssuer/Certificate resources
- `k8s/bnk-prerequisites` — BNK namespaces must exist

## Outputs

- `cluster_issuer_name` — CA-backed ClusterIssuer consumed by BNK components
- `ca_secret_name` — Secret containing the generated CA keypair
- `cert_issuer_ready` — Boolean gate output
