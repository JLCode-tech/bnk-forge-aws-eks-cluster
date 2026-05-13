# Changelog

All notable changes to this module will be documented in this file.

## [3.0.0] - 2026-02-11

### Added
- **OTEL telemetry certificates** via cert-manager Certificate CRD
  - `external-otelsvr-secret` for OTEL collector server (replaces static FLO Helm cert)
  - `external-f5ingotelsvr-secret` for F5 Ingress OTEL server
  - Per F5 CloudDocs otel-certs.html spec (RSA 4096, PKCS1, 360-day duration)
  - Auto-rotate 30 days before expiry via cert-manager
- New variables: `bnk_namespace`, `create_otel_certs`
- New outputs: `otel_server_cert_secret_name`, `otel_f5ing_server_cert_secret_name`, `bnk_certs_ready`
- Certificate verification step with status reporting

### Verified on live cluster (aws-sydney-bnk-demo-cluster, BNK 2.2 GA)
- All cert-manager Certificate CRD fields validated against live CRD schema (v1.16.1)
- **CWC certs NOT needed**: FLO v2.9.27 auto-creates cert-manager Certificates
  for CWC (tls-spkcwc-grpc-svr, tls-csmqkview-grpc-*, tls-cwc-amqp-clt, etc.)
  The F5 docs cwc-certificate.html describes the OLD pre-FLO manual deployment.
- **OTEL cert IS needed**: FLO Helm embeds `external-otelsvr-secret` as a static
  Opaque secret (issuer: CN=arm-ca, expires Feb 2026). This cert does NOT
  auto-rotate. Our cert-manager Certificate CRD replaces it with a managed one.

### Status
- Tested on aws-sydney-bnk-demo-cluster with BNK 2.2 GA

## [2.0.0] - 2025-12-01

### Added
- Jetstack cert-manager v1.16.1 via Helm
- Self-signed ClusterIssuer chain (selfsigned -> CA cert -> CA ClusterIssuer)
- Per F5 BNK 2.2 GA docs recommendation

### Status
- Deployed on live BNK 2.2 cluster

## [1.0.0] - 2025-11-19

### Added
- Initial release
- Core functionality
- Comprehensive README documentation
- Basic example usage

### Status
- Not yet tested in production
