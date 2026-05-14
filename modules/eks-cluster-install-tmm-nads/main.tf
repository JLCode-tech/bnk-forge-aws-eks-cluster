# =============================================================================
# eks-cluster-install-tmm-nads
# =============================================================================
# Creates the two AWS-specific NetworkAttachmentDefinitions the HP variant
# blueprints reference in their CNEInstance CRs:
#   - ens7-ipvlan-l2 → external data-plane interface on the hp-nodes ens7 ENI
#   - ens8-ipvlan-l2 → internal data-plane interface on the hp-nodes ens8 ENI
#
# The Multus CNI install is done by the cloud-agnostic eks-cluster-install-
# multus module (vendored from bnk-forge-catalog-shared); this module
# depends on it via var.multus_ready and only handles the AWS-specific
# bits: tag-discovery of the TMM subnets + the NAD CR applies themselves.
#
# The CNI 'static' IPAM type requires at least one address. We derive the
# placeholder from the first f5-bnk-role-tagged subnet discovered in the
# cluster VPC at apply time, so the NAD is internally consistent with the
# subnet TMM's secondary ENI actually lives on.
#
# Sequence:
#   1. Discover f5-bnk-role=tmm-external and tmm-internal subnets in vpc_id.
#   2. Apply the external NAD (ens7-ipvlan-l2 by default).
#   3. Apply the internal NAD (ens8-ipvlan-l2 by default).

provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key_id
  secret_key = var.aws_secret_access_key
  token      = var.aws_session_token != "" ? var.aws_session_token : null
}

# =============================================================================
# TMM subnet discovery (tag-based, scoped to the cluster VPC)
# =============================================================================
# Same query cneinstall runs, here so the NAD's static-address placeholder
# can be derived from the discovered subnet's CIDR. Means the placeholder is
# inside the actual subnet TMM's ENI lives on — not the hardcoded 10.10.1.1.

data "aws_subnets" "tmm_external_discovered" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  tags = {
    "f5-bnk-role" = "tmm-external"
  }
}

data "aws_subnet" "tmm_external_discovered" {
  for_each = toset(data.aws_subnets.tmm_external_discovered.ids)
  id       = each.value
}

data "aws_subnets" "tmm_internal_discovered" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  tags = {
    "f5-bnk-role" = "tmm-internal"
  }
}

data "aws_subnet" "tmm_internal_discovered" {
  for_each = toset(data.aws_subnets.tmm_internal_discovered.ids)
  id       = each.value
}

# =============================================================================
# Forge-injected kubeconfig
# =============================================================================

resource "local_sensitive_file" "kubeconfig" {
  filename        = "${path.module}/work/kubeconfig"
  file_permission = "0600"
  content         = try(local.forge_kubeconfig, var.forge_kubeconfig_content)
}

locals {
  kubectl = "kubectl --kubeconfig ${local_sensitive_file.kubeconfig.filename}"

  # Sorted lists of discovered subnet CIDRs. Sort = deterministic pick when
  # multiple AZs are tagged; we always take index [0] for the NAD placeholder.
  tmm_external_cidrs = sort([
    for s in data.aws_subnet.tmm_external_discovered : s.cidr_block
  ])
  tmm_internal_cidrs = sort([
    for s in data.aws_subnet.tmm_internal_discovered : s.cidr_block
  ])

  # 3-tier static-address resolution per NAD:
  #   1. Explicit user override → use it verbatim.
  #   2. Discovery returned subnets → cidrhost(cidr, 1) + matching prefix.
  #   3. Both empty → fallback (default F5 reference 10.10.1.1/24).
  #
  # cidrhost(cidr, 1) picks the first usable host in the subnet (.1). The
  # placeholder isn't routed — F5 IPAM operator overrides at runtime — but
  # keeping it inside the subnet matches what the kernel will see when the
  # ENI is configured.
  nad_external_static_address = (
    var.nad_external_static_address != ""
    ? var.nad_external_static_address
    : (
      length(local.tmm_external_cidrs) > 0
      ? "${cidrhost(local.tmm_external_cidrs[0], 1)}/${split("/", local.tmm_external_cidrs[0])[1]}"
      : var.nad_static_address_fallback
    )
  )

  nad_internal_static_address = (
    var.nad_internal_static_address != ""
    ? var.nad_internal_static_address
    : (
      length(local.tmm_internal_cidrs) > 0
      ? "${cidrhost(local.tmm_internal_cidrs[0], 1)}/${split("/", local.tmm_internal_cidrs[0])[1]}"
      : var.nad_static_address_fallback
    )
  )

  nad_external_manifest = templatefile("${path.module}/manifests/nad.yaml.tftpl", {
    nad_name       = var.nad_external_name
    nad_namespace  = var.nad_namespace
    tmm_role       = "tmm-external"
    cni_type       = var.nad_cni_type
    master         = var.nad_external_master
    ipvlan_mode    = var.nad_ipvlan_mode
    static_address = local.nad_external_static_address
  })

  nad_internal_manifest = templatefile("${path.module}/manifests/nad.yaml.tftpl", {
    nad_name       = var.nad_internal_name
    nad_namespace  = var.nad_namespace
    tmm_role       = "tmm-internal"
    cni_type       = var.nad_cni_type
    master         = var.nad_internal_master
    ipvlan_mode    = var.nad_ipvlan_mode
    static_address = local.nad_internal_static_address
  })
}

# =============================================================================
# External NAD — TMM client-facing (ens7-ipvlan-l2)
# =============================================================================

resource "null_resource" "nad_external" {
  triggers = {
    manifest_sha    = sha256(local.nad_external_manifest)
    nad_name        = var.nad_external_name
    nad_namespace   = var.nad_namespace
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "[tmm-nads] applying external NAD ${var.nad_external_name} (ns=${var.nad_namespace}) static=${local.nad_external_static_address}"
      cat <<'MANIFEST' | ${local.kubectl} apply -f -
${local.nad_external_manifest}
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = "kubectl --kubeconfig ${self.triggers.kubeconfig_file} -n ${self.triggers.nad_namespace} delete net-attach-def ${self.triggers.nad_name} --ignore-not-found || true"
  }

  # Gate on the upstream install-multus module's multus_ready output. Forge
  # wires this via the pack manifest; explicit precondition guarantees a
  # plan-time failure if the wiring is dropped.
  lifecycle {
    precondition {
      condition     = var.multus_ready
      error_message = "Multus must be installed before NAD CRs are applied. Wire install-multus.multus_ready into var.multus_ready in the blueprint."
    }
  }
}

# =============================================================================
# Internal NAD — TMM backend-facing (ens8-ipvlan-l2)
# =============================================================================

resource "null_resource" "nad_internal" {
  triggers = {
    manifest_sha    = sha256(local.nad_internal_manifest)
    nad_name        = var.nad_internal_name
    nad_namespace   = var.nad_namespace
    kubeconfig_file = local_sensitive_file.kubeconfig.filename
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "[tmm-nads] applying internal NAD ${var.nad_internal_name} (ns=${var.nad_namespace}) static=${local.nad_internal_static_address}"
      cat <<'MANIFEST' | ${local.kubectl} apply -f -
${local.nad_internal_manifest}
MANIFEST
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    on_failure  = continue
    command     = "kubectl --kubeconfig ${self.triggers.kubeconfig_file} -n ${self.triggers.nad_namespace} delete net-attach-def ${self.triggers.nad_name} --ignore-not-found || true"
  }

  # Gate on the upstream install-multus module's multus_ready output. Forge
  # wires this via the pack manifest; explicit precondition guarantees a
  # plan-time failure if the wiring is dropped.
  lifecycle {
    precondition {
      condition     = var.multus_ready
      error_message = "Multus must be installed before NAD CRs are applied. Wire install-multus.multus_ready into var.multus_ready in the blueprint."
    }
  }
}
